package;

import wrenparse.WrenParser;
import wrenparse.Data;

class Test {
	public static function main() {
		var code:String = sys.io.File.getContent('test/test.wren');
		var parser = new WrenParser(byte.ByteData.ofString(code), "");

		var p = parser.parse();

		trace(p);

		// var stest = "%(math.sin())";
		// var stringParse = new StringParser(stest);
		// trace(stringParse.exec());
	}
}
