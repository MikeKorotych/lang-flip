#!/usr/bin/env bash
# Fetch frequency-ordered word lists for Ukrainian and Russian and write
# cleaned versions next to the Swift sources. The output files are committed
# to the repo so end-users don't need network access to build the app.
#
# Source:
#   - hermitdave/FrequencyWords — top 50k from OpenSubtitles 2018, one word
#     per line followed by frequency count
#
# Cleaning:
#   - lowercase
#   - keep only the word column (drop frequency)
#   - keep only words made of language-specific letters (no digits / punct)
#   - keep words 3 chars or longer
#   - dedupe (preserves frequency ordering of the first occurrence)
#   - cross-language contamination filter: OpenSubtitles UK transcripts
#     contain a lot of Russian content (mistagged or dubbed-over media),
#     so a word like "хотел" appears in both lists. We exclude any word
#     whose frequency in the OTHER language is >= CROSS_RATIO times its
#     own — that scrubs heavy contamination ("хотел" 73× more common in
#     RU) while leaving real cognates intact ("так" 21×, "люди" 30×,
#     "день" 32×).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$ROOT_DIR/Sources/LangFlip/Dictionaries"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$OUT_DIR"

UK_URL="https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/uk/uk_50k.txt"
RU_URL="https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt"

# Words where the OTHER language is >= this many times more frequent are
# treated as contamination and dropped. Tuned empirically on the 2018
# OpenSubtitles lists — see header comment.
CROSS_RATIO=50

echo "→ Fetching raw frequency lists…"
curl -fsSL "$UK_URL" -o "$TMP_DIR/uk_raw.txt"
curl -fsSL "$RU_URL" -o "$TMP_DIR/ru_raw.txt"

# Build keyed maps: word -> freq, lowercased.
awk '{print tolower($1) "\t" $2}' "$TMP_DIR/uk_raw.txt" > "$TMP_DIR/uk_freq.tsv"
awk '{print tolower($1) "\t" $2}' "$TMP_DIR/ru_raw.txt" > "$TMP_DIR/ru_freq.tsv"

clean_dict () {
  # $1 = own freq tsv, $2 = other freq tsv, $3 = allowed-letter regex,
  # $4 = output file, $5 = label
  local own="$1" other="$2" regex="$3" out="$4" label="$5"
  perl -CSDA -Mutf8 - "$own" "$other" "$CROSS_RATIO" "$regex" > "$out" <<'PERL'
use strict;
use warnings;
use utf8;

my ($own_path, $other_path, $ratio, $regex) = @ARGV;
my %other_freq;
my %seen;

open my $other_fh, '<:encoding(UTF-8)', $other_path or die "open $other_path: $!";
while (my $line = <$other_fh>) {
    chomp $line;
    my ($word, $freq) = split /\t/, $line;
    next unless defined $word && defined $freq;
    $other_freq{$word} = 0 + $freq;
}
close $other_fh;

open my $own_fh, '<:encoding(UTF-8)', $own_path or die "open $own_path: $!";
while (my $line = <$own_fh>) {
    chomp $line;
    my ($word, $own_f) = split /\t/, $line;
    next unless defined $word && defined $own_f;
    next if length($word) < 3;
    next unless $word =~ /$regex/;
    my $other_f = $other_freq{$word} // 0;
    next if $own_f > 0 && $other_f >= $own_f * $ratio;
    next if $seen{$word}++;
    print "$word\n";
}
close $own_fh;
PERL
  local count
  count=$(wc -l < "$out" | tr -d ' ')
  echo "  ✓ $(basename "$out") — $count words ($label)"
}

echo "→ Building Ukrainian list…"
clean_dict "$TMP_DIR/uk_freq.tsv" "$TMP_DIR/ru_freq.tsv" \
  '^[абвгґдеєжзиіїйклмнопрстуфхцчшщьюя]+$' \
  "$OUT_DIR/uk-words.txt" "uk"

echo "→ Building Russian list…"
clean_dict "$TMP_DIR/ru_freq.tsv" "$TMP_DIR/uk_freq.tsv" \
  '^[абвгдеёжзийклмнопрстуфхцчшщъыьэюя]+$' \
  "$OUT_DIR/ru-words.txt" "ru"

echo
echo "Done. Re-run \`make app\` to bundle the new dictionaries into the .app."
