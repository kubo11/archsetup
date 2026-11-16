#!/usr/bin/env bash

REPO_URL="https://aur.archlinux.org/yay.git'"
REPO_DIR="/tmp"
DEPS=("git"                \
      "base-devel"         \
      "extra/go"           \
      "python-build"       \
      "python-setuptools"  \
      "python-wheel"       \
      "python-installer"   \
      "python-poetry-core" \
)
PROGS=("makemkv"           \
	"tev"              \
)

which yay > /dev/null
if [ $? -ne 0 ] ; then
    for dep in "${DEPS[@]}" ; do
        pacman -S $dep
    done

    cd $REPO_DIR
    git clone $REPO_URL
    cd yay

    makepkg -si --noconfirm
fi

for prog in "${PROGS[@]}" ; do
    yay -S $prog
done

