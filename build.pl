#!/usr/bin/perl
# Desk builder. Runs the same locally (Git Bash perl) and in GitHub Actions.
#   perl build.pl [--top N] [--limit N] [--previous previous.json] [--out dist] [--seed]
# desk.json decides which sections are built:
#   "leveraged": true  -> Gate leveraged-token rebalance screen (3L/3S/5L/5S)
#   "futures":   true  -> KuCoin USDT perpetuals: funding, volatility, depth, correlation
# A section whose venue cannot be reached is carried forward from the previous
# data.json (or data/seed.json) and marked stale.
# Public market data only: no API keys, no accounts, no orders. Not investment advice.
use strict; use warnings; use JSON::PP; use File::Path qw(make_path); use POSIX qw(strftime);
use Time::HiRes qw(sleep);

my %o = (top => 40, limit => 0, previous => '', out => 'dist', seed => 0);
while (@ARGV) { my $a = shift; if ($a =~ /^--(top|limit|previous|out)$/) { $o{$1} = shift } elsif ($a eq '--seed') { $o{seed} = 1 } }
my $UA  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36';
my $NOW = time; my @log;
sub note { my $m = shift; print "$m\n"; push @log, $m; }
sub curl { my ($url) = @_; my $b = `curl -sS -L --max-time 30 -A '$UA' '$url' 2>/dev/null`; return $b // ''; }
sub js   { my $b = shift; return undef unless defined $b && length $b; my $r = eval { JSON::PP->new->utf8(1)->decode($b) }; return $r; }
sub slurp { my $f = shift; open my $h, '<:raw', $f or return ''; local $/; my $t = <$h>; close $h; $t }
sub rd   { my ($v, $d) = @_; return undef unless defined $v; return sprintf("%.${d}f", $v) + 0 }
sub sig  { my ($v, $n) = @_; return undef unless defined $v; return 0 if $v == 0; return sprintf("%.${n}g", $v) + 0 }
sub mean { return undef unless @_; my $s = 0; $s += $_ for @_; $s / @_ }

my $CFG  = js(slurp('desk.json')) or die "desk.json missing or invalid\n";
my $prev = ($o{previous} && -s $o{previous}) ? js(slurp($o{previous})) : undef;
my $seed = js(slurp('data/seed.json'));
note("previous data: ".($prev ? "found, generated ".($prev->{gen} // '?') : 'none').($seed ? "; seed from ".($seed->{gen} // '?') : ''));
sub fallback { my $k = shift; for my $src ($prev, $seed) { next unless $src && $src->{$k} && @{$src->{$k}{rows} // []}; my %c = %{$src->{$k}}; $c{stale} = 1; return \%c } return undef }

# ---------- KuCoin futures ----------
my $KC = 'https://api-futures.kucoin.com';
sub kc { my $p = shift; for my $t (0..2) { my $r = js(curl("$KC$p")); return $r->{data} if $r && ($r->{code} // '') eq '200000' && defined $r->{data}; sleep(1 + 2 * $t) } return undef }
my (%kcsym, $fut);
if ($CFG->{futures} || $CFG->{leveraged}) {
  my $act = kc('/api/v1/contracts/active');
  if (ref $act eq 'ARRAY') {
    my @u = grep { ($_->{type} // '') eq 'FFWCSX' && ($_->{settleCurrency} // '') eq 'USDT' && ($_->{status} // '') eq 'Open'
                   && ($_->{assetClass} // 'CRYPTO') eq 'CRYPTO' && $_->{lastTradePrice} && $_->{turnoverOf24h} } @$act;
    for (@u) { my $b = $_->{baseCurrency}; $b = 'BTC' if $b eq 'XBT'; $kcsym{$b} = $_->{symbol} }
    note("kucoin: ".scalar(@u)." open USDT crypto perpetuals");
    if ($CFG->{futures}) {
      @u = sort { $b->{turnoverOf24h} <=> $a->{turnoverOf24h} } @u;
      splice(@u, $o{top}) if @u > $o{top}; splice(@u, $o{limit}) if $o{limit} && @u > $o{limit};
      my (@rows, %ret);
      for my $c (@u) {
        my $s = $c->{symbol}; my $base = $c->{baseCurrency} eq 'XBT' ? 'BTC' : $c->{baseCurrency};
        my $px = $c->{markPrice} || $c->{lastTradePrice}; my $mult = $c->{multiplier} || 1;
        my $ih = ($c->{fundingRateGranularity} || 28800000) / 3600000;
        my %r = (s => $s, b => $base, px => sig($px, 6), turn => rd($c->{turnoverOf24h}, 0), ih => $ih + 0,
                 oi => rd(($c->{openInterest} // 0) * $mult * $px, 0), chg => rd(($c->{priceChgPct} // 0) * 100, 2));
        if (defined $c->{fundingFeeRate}) { $r{f} = rd($c->{fundingFeeRate} * 100, 4); $r{fa} = rd($c->{fundingFeeRate} * 8760 / $ih * 100, 1) }
        $r{fl} = rd($c->{lastTimeFundingRate} * 100, 4) if defined $c->{lastTimeFundingRate};
        $r{fp} = rd($c->{predictedFundingFeeRate} * 100, 4) if defined $c->{predictedFundingFeeRate};
        # hourly candles (the API returns the most recent 200): realised volatility, zero-mean as in the source notebook
        my $k = kc("/api/v1/kline/query?symbol=$s&granularity=60");
        if (ref $k eq 'ARRAY' && @$k > 30) {
          my @k = sort { $a->[0] <=> $b->[0] } @$k; pop @k;                       # drop the live candle
          my (@lr, %byt); for my $i (1..$#k) { next unless $k[$i][4] > 0 && $k[$i-1][4] > 0 && $k[$i][0] - $k[$i-1][0] == 3600000; my $x = log($k[$i][4] / $k[$i-1][4]); push @lr, $x; $byt{$k[$i][0]} = $x }
          if (@lr >= 24) { my $v = mean(map { $_ * $_ } @lr); my $sh = sqrt($v); my $sd = $sh * sqrt(24);
            $r{sh} = sig($sh, 5); $r{sd} = rd($sd * 100, 2); $r{s8} = rd($sd / sqrt(3) * 100, 2); $r{vol} = rd($sd * sqrt(365) * 100, 0); $r{n} = scalar @lr; $ret{$s} = \%byt }
        }
        # funding history, last 30 days
        my $fh = kc("/api/v1/contract/funding-rates?symbol=$s&from=".(($NOW - 30 * 86400) * 1000)."&to=".($NOW * 1000));
        if (ref $fh eq 'ARRAY' && @$fh) {
          my ($sum, $comp, $pos, $s7, $old) = (0, 1, 0, 0, $NOW * 1000);
          for (@$fh) { my $x = $_->{fundingRate}; $sum += $x; $comp *= 1 + $x; $pos++ if $x > 0; $s7 += $x if $_->{timepoint} >= ($NOW - 7 * 86400) * 1000; $old = $_->{timepoint} if $_->{timepoint} < $old }
          my $days = ($NOW * 1000 - $old) / 86400000; $days = 1 if $days < 1;
          $r{f30} = rd($sum * 100, 3); $r{f30c} = rd(($comp - 1) * 100, 3); $r{f30a} = rd($sum / $days * 365 * 100, 1); $r{fd} = rd($days, 0);
          $r{f7a} = rd($s7 / 7 * 365 * 100, 1) if $days >= 6.5; $r{fpos} = rd(100 * $pos / @$fh, 0);
          $r{cr} = rd($sum * 100 / $days * 30 / $r{sd}, 2) if $r{sd};             # 30 days of funding per 1 daily standard deviation
        }
        # order book: resting notional within x% of mid, average of the two sides
        my $ob = kc("/api/v1/level2/snapshot?symbol=$s");
        if (ref $ob eq 'HASH' && @{$ob->{bids} // []} && @{$ob->{asks} // []}) {
          my ($bb, $ba) = ($ob->{bids}[0][0], $ob->{asks}[0][0]); my $mid = ($bb + $ba) / 2;
          $r{spr} = rd(($ba - $bb) / $mid * 1e4, 2);
          for my $pc ([d15 => 0.15], [d50 => 0.5]) { my ($bl, $al) = (0, 0);
            for (@{$ob->{bids}}) { $bl += $_->[0] * $_->[1] * $mult if $_->[0] >= $mid * (1 - $pc->[1] / 100) }
            for (@{$ob->{asks}}) { $al += $_->[0] * $_->[1] * $mult if $_->[0] <= $mid * (1 + $pc->[1] / 100) }
            $r{$pc->[0]} = rd(($bl + $al) / 2, 0) }
        }
        push @rows, \%r; sleep(0.15);
      }
      if (@rows) {
        # correlation of hourly log returns, 12 most-traded contracts, pairwise on shared hours
        my @cs = map { $_->{s} } grep { $ret{$_->{s}} } @rows; splice(@cs, 12) if @cs > 12; my @m;
        for my $i (0..$#cs) { for my $j (0..$#cs) { my ($a, $b) = ($ret{$cs[$i]}, $ret{$cs[$j]}); my @t = grep { defined $b->{$_} } keys %$a;
            if (@t < 24) { $m[$i][$j] = undef; next } my ($sa, $sb, $sab) = (0, 0, 0); for (@t) { $sa += $a->{$_} ** 2; $sb += $b->{$_} ** 2; $sab += $a->{$_} * $b->{$_} }
            $m[$i][$j] = ($sa > 0 && $sb > 0) ? rd($sab / sqrt($sa * $sb), 2) : undef } }
        $fut = { ts => $NOW, rows => \@rows, corr => { syms => \@cs, m => \@m } };
        note("kucoin futures rows: ".scalar(@rows).", correlation matrix ".scalar(@cs)."x".scalar(@cs));
      }
    }
  } else { note("kucoin futures: unreachable from this machine") }
  if ($CFG->{futures} && !$fut) { $fut = fallback('fut'); note($fut ? "kucoin futures: using earlier data (stale)" : "kucoin futures: no data and nothing to fall back on") }
}

# ---------- Gate leveraged tokens ----------
# Rules (Gate help centre, "ETF rebalancing mechanism"): daily check at 00:00 UTC+8 (16:00 UTC); a rebalance back to
# target also fires at any time once real leverage reaches a limit.
my %LIM = ('3L' => [2.25, 4.125], '3S' => [1.5, 5.25], '5L' => [3.5, 7], '5S' => [3.5, 7]);
my $lt;
if ($CFG->{leveraged}) {
  my $t = js(curl('https://api.gateio.ws/api/v4/spot/tickers'));
  if (ref $t eq 'ARRAY' && @$t > 100) {
    my %px; for (@$t) { $px{$1} = $_ if $_->{currency_pair} =~ /^(.+)_USDT$/ }
    my @rows;
    for my $x (@$t) {
      next unless $x->{currency_pair} =~ /^([A-Z0-9]+?)([35])([LS])_USDT$/ && defined $x->{etf_leverage};
      my ($und, $T, $sd) = ($1, $2 + 0, $3); my $L = $x->{etf_leverage} + 0; my $nav = ($x->{etf_net_value} // 0) + 0;
      next unless $L > 0 && $nav > 0; my $u = $px{$und}; my $lim = $LIM{"$T$sd"};
      # exposure / debt (long) or exposure / cash (short) scales one-for-one with the underlying price
      my $g  = $sd eq 'L' ? sub { $_[0] / ($_[0] - 1) } : sub { $_[0] / ($_[0] + 1) };
      my $mv = sub { my $to = shift; return undef if $sd eq 'L' && ($L <= 1 || $to <= 1); $g->($to) / $g->($L) - 1 };
      my %r = (t => "$und$T$sd", u => $und, T => $T, sd => $sd, lev => rd($L, 3), nav => sig($nav, 6), px => sig($x->{last} + 0, 6),
               vol => rd($x->{quote_volume} // 0, 0), pts => ($x->{etf_pre_timestamp} // 0) + 0);
      $r{prem} = rd(($x->{last} / $nav - 1) * 100, 2) if $x->{last};
      my ($mu, $ml) = ($mv->($lim->[1]), $mv->($lim->[0]));               # underlying move to the upper / lower leverage limit
      $r{mu} = rd($mu * 100, 2) if defined $mu; $r{ml} = rd($ml * 100, 2) if defined $ml;
      my @d = grep { defined } ($mu, $ml); if (@d) { my ($n) = sort { abs($a) <=> abs($b) } @d; $r{near} = rd(abs($n) * 100, 2) }
      my $since = ($sd eq 'L' && $L <= 1) ? undef : 1 / ($g->($T) / $g->($L)) - 1;      # underlying move since leverage was last at target
      $r{since} = rd($since * 100, 2) if defined $since;
      $r{rb} = rd(($sd eq 'L' ? 1 : -1) * ($T - $L) * 100, 1);          # trade in the underlying if reset to target now, % of fund NAV (+ buy, - sell)
      if ($u && $u->{last}) { $r{upx} = sig($u->{last} + 0, 6); $r{uchg} = rd($u->{change_percentage} + 0, 2) if defined $u->{change_percentage};
        $r{pu} = sig($u->{last} * (1 + $mu), 6) if defined $mu; $r{pl} = sig($u->{last} * (1 + $ml), 6) if defined $ml;
        $r{due} = 1 if defined $r{uchg} && abs($r{uchg}) > 1; }
      $r{out} = 1 if $L >= $lim->[1] || $L <= $lim->[0];
      $r{kc} = $kcsym{$und} if $kcsym{$und};
      push @rows, \%r;
    }
    if (@rows) { $lt = { ts => $NOW, rows => \@rows, lim => \%LIM }; note("gate leveraged tokens: ".scalar(@rows)) }
  } else { note("gate: unreachable from this machine") }
  if (!$lt) { $lt = fallback('lt'); note($lt ? "gate leveraged tokens: using earlier data (stale)" : "gate leveraged tokens: no data and nothing to fall back on") }
}
die "no data for any section\n" unless $fut || $lt;

# ---------- write ----------
my $out = { gen => strftime('%d %b %Y %H:%M UTC', gmtime($NOW)), ts => $NOW, refresh_url => $ENV{REFRESH_URL} // '',
  name => $CFG->{name}, sub => $CFG->{sub}, log => \@log };
$out->{fut} = $fut if $fut; $out->{lt} = $lt if $lt;
make_path($o{out});
my $json = JSON::PP->new->utf8(1)->canonical(1)->encode($out);
open my $h, '>:raw', "$o{out}/data.json" or die $!; print $h $json; close $h;
if ($o{seed} && !$o{limit} && !grep { $_ && $_->{stale} } ($fut, $lt)) { make_path('data'); open my $s, '>:raw', 'data/seed.json' or die $!; print $s $json; close $s; print "seed refreshed\n" }
my $tpl = slurp('template.html'); (my $inl = $json) =~ s{</}{<\\/}g;
$tpl =~ s{(<script type="application/json" id="d-data">).*?(</script>)}{$1$inl$2}s or die "template has no d-data block\n";
open $h, '>:raw', "$o{out}/index.html" or die $!; print $h $tpl; close $h;
print "wrote $o{out}/index.html (".length($tpl)." bytes), $o{out}/data.json (".length($json)." bytes)\n";
