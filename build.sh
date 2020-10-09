echo "Macro"
haxe test.hxml

echo "C++"
bin/cpp/Test.exe

echo "JVM"
java -jar bin/jvm/Test.jar

echo "JS"
node bin/js/Test.js

echo "C#"
bin/cs/Test/bin/Test.exe

echo "Python"
python bin/py/Test.py

echo "neko"
neko bin/neko/Test.n

# echo "Lua"
# lua bin/lua/Test.lua

# echo "hashlink"
# hl bin/hl/Test.hl