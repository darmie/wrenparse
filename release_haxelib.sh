#!/bin/sh
rm -f wrenparse.zip
zip -r wrenparse.zip src *.hxml *.json *.md run.n
haxelib submit wrenparse.zip $HAXELIB_PWD --always