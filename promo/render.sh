#!/bin/zsh
# Builds the renderer and renders both cuts of the teaser (with sound) next to this script.
set -e
cd "${0:A:h}"
tmp=$(mktemp -d)
cat Sound.swift PromoRender.swift > $tmp/promo.swift
swiftc -O $tmp/promo.swift -o $tmp/promo 2> >(grep -E "error" >&2 || true)
$tmp/promo pet-notch-teaser.mp4
$tmp/promo --portrait pet-notch-teaser-vertical.mp4
