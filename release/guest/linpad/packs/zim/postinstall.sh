#!/bin/sh
# Notes (Zim) pack: a ready notebook in ~/Notes, plain text files that Linux tools, git and
# VS Code can read, set as Zim's default so it opens straight into it. An existing
# notebook list or ~/Notes content is left alone.
set -eu
home=/root
notes=$home/Notes
mkdir -p "$notes"
if [ ! -e "$notes/notebook.zim" ]; then
    cat > "$notes/notebook.zim" <<'ZIM'
[Notebook]
version=0.4
name=Notes
interwiki=
home=Home
icon=
document_root=
shared=True
endofline=unix
disable_trash=False
profile=
ZIM
fi
if [ ! -e "$notes/Home.txt" ]; then
    cat > "$notes/Home.txt" <<'PAGE'
Content-Type: text/x-zim-wiki
Wiki-Format: zim 0.6

====== Home ======

Your notes live in ~/Notes as plain text files, one per page.

[ ] Try a checkbox: Ctrl+1 cycles it
Links: [[Ideas]] makes a new page
PAGE
fi
list=$home/.config/zim/notebooks.list
if [ ! -e "$list" ]; then
    mkdir -p "${list%/*}"
    printf '[NotebookList]\nDefault=%s\n%s\n' "file://$notes" "file://$notes" > "$list"
fi
