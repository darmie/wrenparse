package wrenparse;

import haxe.io.UInt8Array;
import byte.ByteData;
import wrenparse.VM;
import wrenparse.objects.ObjString;
import haxe.io.BytesBuffer;
import wrenparse.Utils.*;

typedef TBuffer<T> = {
    data:Array<T>,
    count:Int,
    capacity:Int,
    vm:VM
}

@:forward(data, count, capacity, vm)
abstract Buffer<T>(TBuffer<T>) from TBuffer<T> to TBuffer<T> {
    public inline function new(vm:VM) {
        this = {
            data: [],
            count: 0,
            capacity: 0,
            vm:vm
        };
    }


    public inline function clear(){
        // todo: vm.reallocate()
        this = {
            data: [],
            count: 0,
            capacity: 0,
            vm:this.vm
        };
    }

    public inline function fill(data:T, count:Int) {
        if(this.capacity < this.count + count){
            var capacity = wrenPowerOf2Ceil(this.count + count);
            // todo: VM reallocate  
            this.capacity = capacity;
        }

        var i = 0;
        while(i < count){
            this.data[this.count++] = data;
        }
    }

    public inline function write(data:T) {
        fill(data, 1);
    }
}



typedef StringBuffer = Buffer<ObjString>;


@:forward(data, count, capacity, fill, write, vm, clear)
abstract SymbolTable(StringBuffer) from StringBuffer to StringBuffer {


    public function add(name:String){
        var symbol:ObjString = new ObjString(); // todo AS_STRING(wrenNewStringLength(vm, name, length));
        this.vm.pushRoot(symbol);
        this.write(symbol);
        this.vm.popRoot();
    }

    public function find(v:String) {
        for(i in 0...this.count){
           var found = this.data[i].value[v.length - 1] == v; //UInt8Array.fromArray(.slice(0, v.length - 1)).getData().bytes.toString() == v;
            if((v.length == this.data[i].length) && found){
                return i;
            }
        }
        return -1;
    }
}


typedef IntBuffer = Buffer<Int>;
typedef ByteBuffer = Buffer<Int>;

// typedef TBBuffer = {
//     data:BytesBuffer,
//     count:Int,
//     capacity:Int,
//     vm:VM
// }

// @:forward(data, count, capacity, vm)
// abstract ByteBuffer(TBBuffer) from TBBuffer to TBBuffer {
//     public inline function new(vm:VM) {
//         this = {
//             data: new BytesBuffer(),
//             count: 0,
//             capacity: 0,
//             vm:vm
//         };
//     }

//     public inline function clear(){
//         // todo: vm.reallocate()
//         this = {
//             data: new BytesBuffer(),
//             count: 0,
//             capacity: 0,
//             vm:this.vm
//         };
//     }

//     public inline function fill(data:Int, count:Int) {
//         if(this.capacity < this.count + count){
//             var capacity = wrenPowerOf2Ceil(this.count + count);
//             // todo: VM reallocate  
//             this.capacity = capacity;
//         }

//         var i = 0;
//         while(i < count){
//            // this.data[this.count++] = data;
//            var b = new BytesBuffer();
//            b.addByte(data);
//            this.data.addBytes(b.getBytes(), this.count++, b.length);
//         }
//     }

//     public inline function write(data:Int) {
//         fill(data, 1);
//     }
// }