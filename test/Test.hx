package;

import haxe.Timer;
import wrenparse.WrenParser;
import wrenparse.Data;

class Test {
	public static function main() {
		var code:String = sys.io.File.getContent('test/test.wren');
		Sys.println(Timer.measure(runner.bind(code)));
	}

	public static function runner(code):Dynamic{
		
		var parser = new WrenParser(byte.ByteData.ofString(code), "");

		parser.parse();

		return "";
	

		// var stest = "%(math.sin())";
		// var stringParse = new StringParser(stest);
		// trace(stringParse.exec());
	}
}
