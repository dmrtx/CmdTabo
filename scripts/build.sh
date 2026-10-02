#!/bin/zsh
set -eu
project_dir=${0:A:h:h}
mkdir -p "$project_dir/build"
xcrun clang -dynamiclib -fobjc-arc -Wall -Wextra -Werror -framework AppKit \
    "$project_dir/Sources/CmdTabo.m" -o "$project_dir/build/CmdTabo.dylib"
codesign --force --sign - "$project_dir/build/CmdTabo.dylib"
printf '%s\n' "$project_dir/build/CmdTabo.dylib"
