package;

import haxe.Timer;
import wrenparse.WrenParser;
import wrenparse.Data;

class Test {
	public static function main() {
		var code:String = sys.io.File.getContent('test/test.wren');
		var parser = new WrenParser(byte.ByteData.ofString(code), "");
		Sys.println(Timer.measure(runner.bind(parser)));
	}

	public static function runner(parser:WrenParser) {
		var p = parser.parse();
		var buf = new StringBuf();
		for (x in p) {
			switch x {
				case SError(msg, _, line):
					buf.add('[Line: ${line}] ${msg} \n');
				case _: continue;
			}
		}
		return buf.toString();
	}
}
