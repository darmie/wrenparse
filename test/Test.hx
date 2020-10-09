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

	public static function runner(parser:WrenParser){
		parser.parse();
		return "";
	}
}
