#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  mapfile -d '' files < <(find src app test -type f -name '*.hs' -print0)
fi

if [ "${#files[@]}" -eq 0 ]; then
  exit 0
fi

violations=0

while IFS=: read -r file line text; do
  printf '%s:%s: Cortex code must not import Logos: %s\n' "$file" "$line" "$text" >&2
  violations=1
done < <(
  perl -we '
    use strict;
    use warnings;

    my $package_qualifier = qr/"[^"]+"\s+/;
    my $qualified = qr/qualified\s+/;
    my $logos_import =
      qr/^\s*import\s+(?:(?:$package_qualifier)?(?:$qualified)?|(?:$qualified)?(?:$package_qualifier)?)Logos(?:\.|\s|$)/;

    for my $file (@ARGV) {
      open my $fh, "<", $file or die "$file: $!";
      my $line_number = 0;
      while (my $line = <$fh>) {
        ++$line_number;
        if ($line =~ /$logos_import/) {
          chomp $line;
          $line =~ s/^\s+|\s+$//g;
          print "$file:$line_number:$line\n";
        }
      }
      close $fh;
    }
  ' "${files[@]}"
)

exit "$violations"
