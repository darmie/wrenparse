import "beverages"
import "desserts" for Tiramisu, IceCream

// foreign object
foreign class NativeObject {}

class Person {}
class Boy is Person {
	construct new(){
	    if(a){
			a = ~1
		}
		super.a
	}
	name=(val){"hello"}
	
	name{"boy"}
	foreign static runner{}
	method(var1, var2){
		var b = {
			"k": var1,
			"hey": var2
		}
		var b2 = {}
		if (n % 2 == 0) n = n / 2 else n = 3 * n + 1
		var n = 27
		while (n != 1) {
			if (n % 2 == 0) {
				n = n / 2
			} else {
				n = 3 * n + 1
			}
		}
		for (i in 1..100) {
  			System.print(i)
		}
		for (i in [1, 2, 3, 4]) {
			System.print(i)           //> 1
  			if (i == 3) break  
		}
		var a = b = c
		var iter_ = null
		var seq_ = 1..100
		while (iter_ = seq_.iterate(iter_)) {
			var i = seq_.iteratorValue(iter_)
			System.print(i)
		}		
		if(a & 3 == 1 && b % 5 && c == {"k": 4}){ 
			1*2
			0
			1234
			-5678
			3.14159
			1.0
			-12.34
			0.0314159e02
			0.0314159e+02
			314.159e-02
		}
		boy = person
		var arr = []
		var arr2 = [1, 5]
		call(4, 5, (4+5))
		arr2[1...-5]
		arr2[n...k]
		boy.method(false)
		boy.girl.person.call(val.tables, arr2[1], null)
		val.tables
		null
		System.print(false && 1)

		System.print(a = "after")
		
		var isDone = false || true 
		System.print(1 != 2 ? "math is sane" : "math is not sane!")


		{
			blockStatement
		}

		newFn.new{|a, b, c|
			return
		}

		newFn.new{a}

		System.print((2 * (6 - (2 + 2))))

		10.sin // sin value of 10
		[1, 2, 3].isEmpty //> false
		System.print({"key":"value"}.containsKey("key"))
	}
}
// /*
// 	/* Block comment */
// */
var arr = [
  1,
  2,
  3
]


System.print("%(interpolate)")