#!/usr/bin/env bash
set -euo pipefail

allowed_regex='^(AllowAmbiguousTypes|BlockArguments|CPP|MagicHash|OverlappingInstances|PackageImports|PartialTypeSignatures|StrictData|TemplateHaskell|UnboxedTuples|UndecidableInstances)$'

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  mapfile -d '' files < <(find src src-platform src-logos app test test-logos -type f -name '*.hs' -print0)
fi

if [ "${#files[@]}" -eq 0 ]; then
  exit 0
fi

violations=0

while IFS=: read -r file line extension; do
  if [[ ! "$extension" =~ $allowed_regex ]]; then
    printf '%s:%s: LANGUAGE %s is not in the file-local allowlist\n' "$file" "$line" "$extension" >&2
    violations=1
  fi
done < <(
  perl -we '
    use strict;
    use warnings;

    for my $file (@ARGV) {
      open my $fh, "<", $file or die "$file: $!";
      my $line_number = 0;
      while (my $line = <$fh>) {
        ++$line_number;
        while ($line =~ /\{-#\s*LANGUAGE\s+(.+?)#-\}/g) {
          my $body = $1;
          for my $extension (split /,/, $body) {
            $extension =~ s/^\s+|\s+$//g;
            print "$file:$line_number:$extension\n" if length $extension;
          }
        }
      }
      close $fh;
    }
  ' "${files[@]}"
)

if [ "$violations" -ne 0 ]; then
  cat >&2 <<'EOF'

Move project-wide extensions to the common shared-properties stanza in cortex.cabal.
Only genuinely file-local extensions may remain as LANGUAGE pragmas.
EOF
fi

exit "$violations"
