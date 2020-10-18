package;

import wrenparse.VM;
import haxe.Timer;
import wrenparse.WrenParser;
import wrenparse.Data;

class Test {
	public static function main() {
		#if !WREN_COMPILE
		var code:String = sys.io.File.getContent('test/test.wren');
		var parser = new WrenParser(byte.ByteData.ofString(code), "");
		Sys.println(Timer.measure(runner.bind(parser)));
		#else
		Sys.println(Timer.measure(runner2));
		#end
	}

	public static function runner(parser:WrenParser) {
		try {
			var p = parser.parse();
			var buf = new StringBuf();
			for (x in p) {
				switch x {
					case SError(msg, _, line):
						buf.add('[Line: ${line}] ${msg} \n');
					case _:
						continue;
				}
			}
			return buf.toString();
		} catch (e:haxe.Exception) {
			trace(e.details());
			throw e;
		}
	}

	public static function runner2() {
		var code:String = sys.io.File.getContent('test/test3.wren');
		var config:VMConfig = {};
		VM.initConfiguration(config);
		{
			config.writeFn = (v, text) -> {
				trace(text);
			};
			config.errorFn = (vm:VM, type:ErrorType, moduleName:String, line:Int, message:String) -> {
				var buf = new StringBuf();
				switch type {
					case WREN_ERROR_COMPILE: buf.add('[MODULE $moduleName][COMPILE ERROR]: ');
					case WREN_ERROR_RUNTIME: buf.add('[MODULE $moduleName][RUNTIME ERROR]: ');
					case WREN_ERROR_STACK_TRACE: buf.add('[MODULE $moduleName][TRACE]: ');
				}
				buf.add(message);
				trace(buf.toString());
			};
		}
		var vm:VM = new VM(config);
		var res = vm.interpret("main", code);
		if(res == WREN_RESULT_COMPILE_ERROR){
		
		}
		return res;
	}
}
