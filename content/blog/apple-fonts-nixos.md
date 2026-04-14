+++
title = "I refused to give up Apple fonts when I switched to NixOS"
date = 2026-01-13

[taxonomies]
tags = ["nixos", "nix", "fonts", "rice", "cursed"]
+++

I had a really slick KDE setup on Arch — custom theme, everything looking just right — and a big part of that was Apple's fonts. San Francisco for the UI, SF Mono in the terminal. On Arch this was easy: install `apple-fonts` from the AUR, done, move on with your life.

Then I switched to NixOS. No AUR. No prepackaged Apple fonts in nixpkgs (for obvious licensing reasons). But I was not about to redo my whole theme with different fonts. I needed these.

Apple hosts all of their fonts as DMG downloads on their developer site — no Apple ID required. I found [a gist by robbins](https://gist.github.com/robbins/dccf1238e971973a6a963b04c486c099) that already had a working Nix derivation for this. Grabbed it, plugged it in. Easy.

<!-- more -->

Worked great — for about two weeks. Then `nix build` broke because the hash didn't match anymore. Apple repackaged the DMG or rotated something on their CDN. I ran `nix-prefetch-url`, grabbed the new hash, updated, rebuilt. Fine.

Two weeks later, same thing. And again after that. Turns out Apple just periodically repacks these DMGs, which changes the hash, which breaks any Nix derivation pointing at them.

## I got tired of updating hashes

After the fourth or fifth time doing `nix-prefetch-url` → update hash → rebuild → push, I just downloaded all four DMGs (SF Pro, SF Compact, SF Mono, New York) and threw them on my own file server.

```nix
pro = fetchurl {
  url = "https://files.bspwr.com/.../SF-Pro.dmg";
  sha256 = "sha256-u7cLbIRELSNFUa2OW/ZAgIu6vbmK/8kXXqU97xphA+0=";
};
```

Hashes haven't changed since. Because they're my files now. Problem gone.

## Extracting fonts from Apple's DMGs

The annoying part is that Apple doesn't just ship you a zip of `.otf` files. It's a DMG containing a `.pkg` containing a `Payload~` archive. Three layers of Apple packaging. But `p7zip` eats all of it, so the install phase is just a chain of `7z x`:

```nix
{ lib, stdenv, fetchurl, p7zip }:

stdenv.mkDerivation rec {
  pname = "apple-fonts";
  version = "1";

  pro = fetchurl { /* ... */ };
  compact = fetchurl { /* ... */ };
  mono = fetchurl { /* ... */ };
  ny = fetchurl { /* ... */ };

  nativeBuildInputs = [ p7zip ];
  dontUnpack = true;

  installPhase = ''
    7z x ${pro}
    cd SFProFonts
    7z x 'SF Pro Fonts.pkg'
    7z x 'Payload~'
    mkdir -p $out/fontfiles
    mv Library/Fonts/* $out/fontfiles
    cd ..

    # ...same thing for mono, compact, ny...

    mkdir -p $out/usr/share/fonts/OTF $out/usr/share/fonts/TTF
    mv $out/fontfiles/*.otf $out/usr/share/fonts/OTF
    mv $out/fontfiles/*.ttf $out/usr/share/fonts/TTF
    rm -rf $out/fontfiles
  '';

  meta = {
    description = "Apple San Francisco, New York fonts";
    homepage = "https://developer.apple.com/fonts/";
    license = lib.licenses.unfree;
  };
}
```

Drop it in your config:

```nix
fonts.packages = [
  (pkgs.callPackage ./modules/apple_fonts.nix { })
];
```

## Is this legal?

The fonts are freely downloadable from Apple's developer site without authentication. The license says they're for use on Apple platforms, which NixOS is definitely not. So probably not, technically. But they're not behind a login, not DRM'd, and I've never heard of Apple going after anyone for using San Francisco on Linux. Do what you want with that information.

My terminal looks great and I sleep fine.
