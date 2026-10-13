#!/usr/bin/perl

# Compiles the kb_options the planner writes (see the planOptions tests in
# tst_ServiceLogic.qml) with xkbcli, against Omarchy's own XKB option files,
# and checks on every layout that the Caps switch key switches and that
# Compose is where the note says it is.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Spec;
use FindBin;
use Test::More;

my $repo = abs_path(File::Spec->catdir($FindBin::Bin, ".."));
my $xkb = File::Spec->catdir($repo, "tests", "fixtures", "xkb");

my $xkbcli = (grep { -x } map { File::Spec->catfile($_, "xkbcli") } File::Spec->path)[0];
plan skip_all => "xkbcli is not installed" unless $xkbcli;

sub keymap {
  my ($layouts, $options) = @_;
  open(my $out, "-|", $xkbcli, "compile-keymap", "--include", $xkb, "--include-defaults",
    "--layout", $layouts, "--options", $options) or die "xkbcli: $!";
  local $/;
  my $text = <$out>;
  close($out);
  die "xkbcli failed for $layouts / $options\n" if $? != 0;
  return $text;
}

# The level-1 symbol of KEY in GROUP (1-based). A key with one group applies
# that group to every layout.
sub symbol {
  my ($text, $key, $group) = @_;
  my ($body) = $text =~ /key <\Q$key\E>\s*\{(.*?)\n\t\};/s or return "";
  my %groups;
  while ($body =~ /symbols\[(\d)\]\s*=\s*\[\s*([^,\]\s]+)/g) { $groups{$1} = $2 }
  return $groups{$group} // (keys(%groups) == 1 ? (values %groups)[0] : "");
}

my %home = (rctrl => "RCTL", menu => "COMP", ralt => "RALT");

for my $layouts ("us,gr", "us,de") {
  my $before = keymap($layouts, "omarchy:shift_caps_compose,grp:caps_toggle");
  is(symbol($before, "CAPS", $_), "Caps_Lock", "$layouts: Omarchy's option silences the Caps switch (group $_)")
    for 1, 2;

  for my $case (
    ["compose:rctrl,grp:caps_toggle,grp_led:caps", "rctrl"],
    ["compose:rctrl,grp:shift_caps_toggle", "rctrl"],
    ["compose:rctrl,grp:alt_caps_toggle", "rctrl"],
    ["compose:menu,lv5:rctrl_switch,grp:caps_toggle", "menu"],
  ) {
    my ($options, $compose) = @$case;
    my $text = keymap($layouts, $options);
    for my $group (1, 2) {
      my $caps = symbol($text, "CAPS", $group);
      my $switch = $options =~ /grp:caps_toggle/ ? "ISO_Next_Group" : "Caps_Lock";
      is($caps, $switch, "$layouts / $options: Caps Lock (group $group)");
      is(symbol($text, $home{$compose}, $group), "Multi_key", "$layouts / $options: Compose (group $group)");
    }
  }

  # The Shift+Caps and Alt+Caps switches keep plain Caps Lock on level 1 and
  # switch on the modified level, so look for the group action on the key.
  for my $hotkey ("grp:shift_caps_toggle", "grp:alt_caps_toggle") {
    my $text = keymap($layouts, "compose:rctrl,$hotkey");
    my ($body) = $text =~ /key <CAPS>\s*\{(.*?)\n\t\};/s;
    like($body, qr/ISO_Next_Group/, "$layouts / $hotkey: Caps Lock switches");
  }

  # Right Alt is only Compose on layout 1: gr and de keep it as AltGr.
  my $ralt = keymap($layouts, "compose:ralt,grp:caps_toggle");
  is(symbol($ralt, "RALT", 1), "Multi_key", "$layouts: Right Alt Compose on layout 1");
  isnt(symbol($ralt, "RALT", 2), "Multi_key", "$layouts: Right Alt is not Compose on layout 2");
}

done_testing();
