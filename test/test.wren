import "beverages"
import "desserts" for Tiramisu, IceCream

// foreign object
foreign class NativeObject {}


var arrayGet = g[0]

f.call(10, 
20,
30)

class Person {
    construct new(){}
    static runner(){}
    setter=(val){}
    getter{}
    method(c, b){}
    foreign static item()

    foreign setter=(val)

    foreign get

    foreign method()

    +(other) { }
    ! { }
    [index] {}
    [index]=(value) {}
    [x, y]=(value) {}
    is(item){}
}

class Boy is Person {}

while(i < n){
    break
}
for(i in [a, b, c]){
    break
}

var a = b = c
a = d
if(a >= c){
    b = [c]
}
 b = [c]
var b = 1...c
for(i in 5..7){
   (a + (c - (d + b)))
   break
}

call("hello")
System.print("hello",
"big")
a.field = ~1 >> 4

if(b && c || a){

}

if(true){
    if(false){}
}

if(a is d){}

var x = 1 != 2 ? "math is sane" : "math is not sane!" // ternary
var object = {
    "key": 4,
    1.2: "hello"
    // here
}
class General {
	construct new(){
	    if(a){
			a = ~1 //unary
		}
		//super.a
	}
	name=(val){"hello"}
	
	name{"boy"}

	foreign static runner()
	method(var1, var2){
		var b = {
			"k": var1,
			"hey": var2
		}
		var b2 = {}
		if (n % 2 == 0) n = n / 2 else n = 3 * n + 1 // single line if-else
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
		for (i in [11,
        2, 
        3, 4]) {
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
		if(a && 3 == 1 && b % 5 && c == {"k": 4}){ 
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
		var arr = [] // empty array
		var arr2 = [1, 5]
		call(4, 5, (4+5))
		arr2[6...-5]
		arr2[n...k]
		boy.method(false)
		person.girl.person.call(val.tables, arr2[1], null)
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
			// return
		}

		newFn.new{a}

		System.print((2 * (6 - (2 + 2))))

		10.sin // sin value of 10
		[1, 2, 3].isEmpty //> false
		System.print({"key":"value"}.containsKey("key"))
	}

	+(other) { "infix + %(other)" }
	-(other) { "infix - %(other)" }
	*(other) { "infix * %(other)" }
	/(other) { "infix / %(other)" }
	%(other) { "infix \% %(other)" }
	<(other) { "infix < %(other)" }
	>(other) { "infix > %(other)" }
	<=(other) { "infix <= %(other)" }
	>=(other) { "infix >= %(other)" }
	==(other) { "infix == %(other)" }
	!=(other) { "infix != %(other)" }
	&(other) { "infix & %(other)" }
	|(other) { "infix | %(other)" }
	is(other) { "infix is %(other)" }

	! { "prefix !" }
	~ { "prefix ~" }
	- { "prefix -" }

	[index] {
    	System.print("Unicorns are not lists!")
  	}

  	[x, y] {
    	System.print("Unicorns are not matrices either!")
  	}

	[index]=(value) {
    	System.print("You can't stuff %(value) into me at %(index)!")
    }
}
/*
	/* Block comment */
	/* Block comment2 *//* Block comment3 */
*/
var arr = [
    1,
  2,
  3
]


System.print("%(interpolate)")

var f = Fn.new{|a, b, c|
  System.print("%(a), %(b), %(c)")
}


f.call().x