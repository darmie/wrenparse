package wrenparse;

import polygonal.ds.ArrayList;

class Utils {
    public static function wrenPowerOf2Ceil(n:Int):Int
    {
      n--;
      n |= n >> 1;
      n |= n >> 2;
      n |= n >> 4;
      n |= n >> 8;
      n |= n >> 16;
      n++;
      
      return n;
    }
}


@:forward(size, free, resize)
abstract FixedArray<T>(ArrayList<T>) from ArrayList<T> to ArrayList<T>{
    public inline function new(size:Int){
        this = new ArrayList<T>(size);
    }

    @:arrayAccess
    public inline function get(i:Int):T {
        return this.get(i);
    }

    @:arrayAccess
    public inline function set(i:Int, v:T) {
        this.set(i, v);
    }
}