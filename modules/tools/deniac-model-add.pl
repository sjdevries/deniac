#!/usr/bin/env perl
# deniac-model-add — resolve a CivitAI / HuggingFace model into a
# `deniac.ai.model-store.models` config entry.
#
# You browse in the real site (that's the GUI), copy the model URL, and
# this turns it into a declarative entry: it resolves the download URL +
# SHA256 (WITHOUT downloading the whole file — CivitAI's API and HF's
# tree API both publish the hash) and prints a Nix attrset to paste into
# your host's `models` list.
#
#   deniac-model-add <url> [--subdir S] [--name N] [--file F]
#                  [--source auto|civitai|huggingface|generic]
#
# Sources:
#   civitai     https://civitai.com/models/<id>?modelVersionId=<v>
#               https://civitai.com/api/v1/model-versions/<v>
#   huggingface https://huggingface.co/<org>/<repo>/resolve/<rev>/<file>
#   generic     any direct file URL (hashed via nix-prefetch-url)
#
# Auth (gated models): set CIVITAI_API_KEY / HF_TOKEN in the env; they
# are sent as Bearer headers to the API/download but are NEVER written
# into the emitted entry (the entry is public config). See research §8.4.

use strict;
use warnings;
use JSON::PP;
use MIME::Base64 qw(encode_base64);

my $usage = <<'USAGE';
Usage: deniac-model-add <url> [options]

  --subdir S    store subdir (llm|image|video|audio|loras|vae|text_encoders|gguf)
                default: inferred from the model type (CivitAI) or 'llm' (HF)
  --name N      filename in the store (default: the source's filename)
  --file F      pick a specific file by name (multi-file versions/repos)
  --source S    auto (default) | civitai | huggingface | generic
  -h, --help    this help
USAGE

# ---- arg parsing ----------------------------------------------------------
my ($url, $subdir, $name, $file, $source) = (undef, undef, undef, undef, 'auto');
my @a = @ARGV;
while (@a) {
  my $x = shift @a;
  if    ($x eq '--subdir') { $subdir = shift @a }
  elsif ($x eq '--name')   { $name   = shift @a }
  elsif ($x eq '--file')   { $file   = shift @a }
  elsif ($x eq '--source') { $source = shift @a }
  elsif ($x eq '-h' || $x eq '--help') { print $usage; exit 0 }
  elsif (!defined $url && $x !~ /^-/)  { $url = $x }
  else { print STDERR "unknown arg: $x\n$usage"; exit 2 }
}
die $usage unless defined $url;

# ---- source detection -----------------------------------------------------
if ($source eq 'auto') {
  if    ($url =~ /civitai\.com/)      { $source = 'civitai' }
  elsif ($url =~ /huggingface\.co/)   { $source = 'huggingface' }
  else                                { $source = 'generic' }
}

# ---- helpers --------------------------------------------------------------
sub http_get {
  my ($u, @hdr) = @_;
  my @h = map { ('-H', $_) } @hdr;
  my $out = `curl -sSL --max-time 120 @h '$u'`;
  die "curl failed (exit $?) for $u\n" if $? != 0;
  return $out;
}

# uppercase/lowercase hex -> SRI "sha256-<base64>"
sub hex_to_sri {
  my ($hex) = @_;
  $hex =~ s/\A0x//i;
  $hex =~ s/[^0-9a-fA-F]//g;
  die "bad sha256 hex: $hex\n" unless length($hex) == 64;
  return "sha256-" . encode_base64(pack("H*", $hex), "");
}

# Fetch a URL through nix-prefetch-url and return its SRI hash.
# nix-prefetch-url prints a nix-base32 hash on stdout; normalise to SRI
# via `nix hash convert` (auto-detects the input format).
sub nix_prefetch_sri {
  my ($u) = @_;
  my $h = `nix-prefetch-url '$u'`;
  die "nix-prefetch-url failed (exit $?) for $u\n" if $? != 0;
  chomp $h;
  my $sri = `nix hash convert --hash-algo sha256 --to sri '$h'`;
  die "nix hash convert failed (exit $?) for $h\n" if $? != 0;
  chomp $sri;
  return $sri;
}

# CivitAI file type -> store subdir
sub civitai_subdir {
  my ($t) = @_;
  $t //= '';
  return 'loras'        if $t =~ /^(lora|locon|lycoris|loha)$/i;
  return 'vae'          if $t =~ /^vae$/i;
  return 'text_encoders' if $t =~ /(textualinversion|embedding|textual inversion)/i;
  return 'video'        if $t =~ /(motion|video|animatediff)/i;
  return 'image';       # Model / checkpoint default
}

sub basename_ { my ($p) = @_; $p =~ s{.*/}{}; return $p; }

# ---- resolve --------------------------------------------------------------
my ($dl_url, $sha_sri, $out_name, $meta_comment);

if ($source eq 'civitai') {
  my ($vid, $mid);
  if    ($url =~ m{/api/v1/model-versions/(\d+)}) { $vid = $1 }
  elsif ($url =~ /[?&]modelVersionId=(\d+)/)       { $vid = $1 }
  elsif ($url =~ m{/models/(\d+)})                { $mid = $1 }
  else { die "could not find a CivitAI model/version id in: $url\n" }

  # only a model id -> take the latest version
  if (!defined $vid && defined $mid) {
    my $mj = decode_json(http_get("https://civitai.com/api/v1/models/$mid"));
    my @vs = @{ $mj->{modelVersions} || [] };
    die "no versions for model $mid\n" unless @vs;
    $vid = $vs[0]{id};
  }

  my @hdr;
  push @hdr, "Authorization: Bearer $ENV{CIVITAI_API_KEY}" if $ENV{CIVITAI_API_KEY};
  my $j = decode_json(http_get("https://civitai.com/api/v1/model-versions/$vid", @hdr));

  my $files = $j->{files} || [];
  my ($f) = defined $file ? (grep { ($_->{name} // '') eq $file } @$files)
                          : ((grep { $_->{primary} } @$files), @$files);
  die "no file found (try --file)\n" unless $f;

  my $hex = $f->{hashes}{SHA256} or die "no SHA256 in CivitAI file\n";
  $dl_url  = $f->{downloadUrl} or die "no downloadUrl in CivitAI file\n";
  $sha_sri = hex_to_sri($hex);
  $out_name //= $f->{name} // "civitai-$vid";
  my $type = $f->{type} // $j->{type} // 'Model';
  my $base = $j->{baseModel} // '';
  my $words = join(", ", @{ $j->{trainedWords} || [] });
  $subdir //= civitai_subdir($type);
  $meta_comment = "CivitAI: $type"
    . ($base ? " / $base" : '')
    . ($words ? "  (trigger: $words)" : '');
}
elsif ($source eq 'huggingface') {
  my ($org, $repo, $rev, $fpath);
  if ($url =~ m{huggingface\.co/([^/]+)/([^/]+)/resolve/([^/]+)/(.+?)/*$}) {
    ($org, $repo, $rev, $fpath) = ($1, $2, $3, $4);
  } else {
    die "for HuggingFace give a resolve URL with a file:\n".
        "  https://huggingface.co/<org>/<repo>/resolve/<rev>/<file>\n";
  }
  my @hdr;
  push @hdr, "Authorization: Bearer $ENV{HF_TOKEN}" if $ENV{HF_TOKEN};

  # get the sha256 from the tree API (no download). The file may be in a
  # subdir; walk the tree for the matching path.
  my ($dir, $leaf) = ($fpath =~ m{^(.*)/([^/]+)$}) ? ($1, $2) : ('', $fpath);
  my $tree_url = "https://huggingface.co/api/models/$org/$repo/tree/$rev"
              . ($dir ? "/$dir" : '');
  my $sha_hex;
  my $tree = eval { decode_json(http_get($tree_url, @hdr)) };
  if ($tree && ref($tree) eq 'ARRAY') {
    for my $e (@$tree) {
      if (($e->{path} // '') eq $fpath) { $sha_hex = $e->{lfs}{oid}; last }
    }
  }
  $dl_url  = "https://huggingface.co/$org/$repo/resolve/$rev/$fpath";
  if ($sha_hex) {
    $sha_sri = hex_to_sri($sha_hex);
  } else {
    # tree API had no lfs.oid (non-LFS file or API miss): hash by fetching.
    warn "tree API had no lfs.oid for $fpath; hashing via nix-prefetch-url (downloads)\n";
    $sha_sri = nix_prefetch_sri($dl_url);
  }
  $out_name //= $leaf;
  $subdir   //= 'llm';
  $meta_comment = "HuggingFace: $org/$repo @ $rev";
}
else {  # generic
  $dl_url = $url;
  $sha_sri  = nix_prefetch_sri($dl_url);
  $out_name //= basename_($url);
  $subdir   //= 'llm';
  $meta_comment = "generic URL";
}

# ---- emit -----------------------------------------------------------------
my $q = sub { my $s = shift // ''; $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g; $s };
print "# $meta_comment\n";
print "{ source = \"$source\";\n";
print "  subdir = \"$subdir\";\n";
print "  name = \"" . $q->($out_name) . "\";\n";
print "  url = \"" . $q->($dl_url) . "\";\n";
print "  sha256 = \"" . $sha_sri . "\"; }\n";
