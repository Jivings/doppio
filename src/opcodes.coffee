
gLong ?= require '../third_party/gLong.js'
util ?= require './util'
types ?= require './types'
{java_throw,BranchException,ReturnException,JavaException} = util
{c2t} = types

root = exports ? this.opcodes = {}

class root.Opcode
  constructor: (@name, params={}) ->
    (@[prop] = val for prop, val of params)
    @execute ?= @_execute
    @byte_count = params.byte_count ? 0

  take_args: (code_array, constant_pool) ->
    @args = (code_array.get_uint(1) for [0...@byte_count])

class root.FieldOpcode extends root.Opcode
  constructor: (name, params) ->
    super name, params
    @byte_count = 2

  take_args: (code_array, constant_pool) ->
    @field_spec_ref = code_array.get_uint(2)
    @field_spec = constant_pool.get(@field_spec_ref).deref()

class root.ClassOpcode extends root.Opcode
  constructor: (name, params) ->
    super name, params
    @byte_count = 2

  take_args: (code_array, constant_pool) ->
    @class_ref = code_array.get_uint(2)
    @class = constant_pool.get(@class_ref).deref()

class root.InvokeOpcode extends root.Opcode
  constructor: (name, params) ->
    super name, params
    @byte_count = 2

  take_args: (code_array, constant_pool) ->
    @method_spec_ref = code_array.get_uint(2)
    # invokeinterface has two redundant bytes
    if @name == 'invokeinterface'
      @count = code_array.get_uint 1
      code_array.index++
      @byte_count += 2
    @method_spec = constant_pool.get(@method_spec_ref).deref()

class root.LoadConstantOpcode extends root.Opcode
  constructor: (name, params) ->
    params.out ?= if name is 'ldc2_w' then [2] else [1]
    super name, params

  take_args: (code_array, constant_pool) ->
    @cls = constant_pool.cls
    @constant_ref = code_array.get_uint @byte_count
    @constant = constant_pool.get @constant_ref

  compile: ->
      if @constant.type is 'String'
        """
        var val = #{@constant.value};
        out0 = rs.string_redirect(val, @cls);
        """
      else if @constant.type is 'class'
        """
        var val = #{@constant.value};
        var jvm_str = rs.get_obj(rs.string_redirect(val,@cls));
        out0 = rs.class_lookup(c2t(rs.jvm2js_str(jvm_str)), true);
        """
      else if @constant.type is 'long'
        "out0 = @constant.value;"
      else
        "out0 = #{@constant.value};"

class root.BranchOpcode extends root.Opcode
  constructor: (name, params={}) ->
    params.byte_count ?= 2
    super name, params

  take_args: (code_array) ->
    @offset = code_array.get_int @byte_count

class root.UnaryBranchOpcode extends root.BranchOpcode
  constructor: (name, params) ->
    super name, {
      execute: (rs) ->
        v = rs.pop()
        throw new BranchException rs.curr_pc() + @offset if params.cmp v
    }

class root.BinaryBranchOpcode extends root.BranchOpcode
  constructor: (name, params) ->
    super name, {
      execute: (rs) ->
        v2 = rs.pop()
        v1 = rs.pop()
        throw new BranchException rs.curr_pc() + @offset if params.cmp v1, v2
    }

class root.PushOpcode extends root.Opcode
  constructor: (name, params) ->
    super name, params
    @out = [1]

  take_args: (code_array) ->
    @value = code_array.get_int @byte_count

  compile: -> "out0=#{@value};"

class root.IIncOpcode extends root.Opcode
  take_args: (code_array, constant_pool, @wide=false) ->
    if @wide
      @name += "_w"
      arg_size = 2
      @byte_count = 5
    else
      arg_size = 1
      @byte_count = 2
    @index = code_array.get_uint arg_size
    @const = code_array.get_int arg_size

  compile: -> "rs.put_cl(#{@index},rs.cl(#{@index})+#{@const})"

class root.LoadOpcode extends root.Opcode
  constructor: (name, params={}) ->
    params.out ?= if name.match /[ld]load/ then [2] else [1]
    super name, params
    @var_num = parseInt @name[6]  # sneaky hack, works for name =~ /.load_\d/

  compile: -> "out0=rs.cl(#{@var_num});"

class root.LoadVarOpcode extends root.LoadOpcode
  take_args: (code_array, constant_pool, @wide=false) ->
    if @wide
      @name += "_w"
      @byte_count = 3
      @var_num = code_array.get_uint 2
    else
      @byte_count = 1
      @var_num = code_array.get_uint 1

class root.StoreOpcode extends root.Opcode
  constructor: (name, params={}) ->
    super name, params
    @var_num = parseInt @name[7]  # sneaky hack, works for name =~ /.store_\d/

  compile: ->
    if @name.match /[ld]store/
      "rs.put_cl2(#{@var_num},rs.pop2())"
    else
      "rs.put_cl(#{@var_num},rs.pop())"

class root.StoreVarOpcode extends root.StoreOpcode
  take_args: (code_array, constant_pool, @wide=false) ->
    if @wide
      @name += "_w"
      @byte_count = 3
      @var_num = code_array.get_uint 2
    else
      @byte_count = 1
      @var_num = code_array.get_uint 1

class root.SwitchOpcode extends root.BranchOpcode
  constructor: (name, params) ->
    super name, params
    @byte_count = null

  execute: (rs) ->
    key = rs.pop()
    throw new BranchException(
      rs.curr_pc() + if @offsets[key]? then @offsets[key] else @_default
    )

class root.LookupSwitchOpcode extends root.SwitchOpcode
  take_args: (code_array, constant_pool) ->
    # account for padding that ensures alignment
    padding_size = (4 - code_array.index % 4) % 4
    code_array.index += padding_size
    @_default = code_array.get_int(4)
    @npairs = code_array.get_int(4)
    @offsets = {}
    for [0...@npairs]
      match = code_array.get_int(4)
      offset = code_array.get_int(4)
      @offsets[match] = offset
    @byte_count = padding_size + 8 * (@npairs + 1)

class root.TableSwitchOpcode extends root.SwitchOpcode
  take_args: (code_array, constant_pool) ->
    # account for padding that ensures alignment
    padding_size = (4 - code_array.index % 4) % 4
    code_array.index += padding_size
    @_default = code_array.get_int(4)
    @low = code_array.get_int(4)
    @high = code_array.get_int(4)
    @offsets = {}
    total_offsets = @high - @low + 1
    for i in [0...total_offsets]
      offset = code_array.get_int(4)
      @offsets[@low + i] = offset
    @byte_count = padding_size + 12 + 4 * total_offsets

class root.NewArrayOpcode extends root.Opcode
  constructor: (name, params) ->
    super name, params
    @byte_count = 1
    @arr_types = {4:'Z',5:'C',6:'F',7:'D',8:'B',9:'S',10:'I',11:'J'}

  take_args: (code_array,constant_pool) ->
    type_code = code_array.get_uint 1
    @element_type = @arr_types[type_code]

class root.MultiArrayOpcode extends root.Opcode
  constructor: (name, params={}) ->
    params.byte_count ?= 3
    super name, params

  take_args: (code_array, constant_pool) ->
    @class_ref = code_array.get_uint 2
    @class = constant_pool.get(@class_ref).deref()
    @dim = code_array.get_uint 1

  execute: (rs) ->
    counts = rs.curr_frame().stack.splice(rs.length-@dim)
    init_arr = (curr_dim) =>
      return 0 if curr_dim == @dim
      typestr = @class[curr_dim..]
      rs.init_object typestr, (init_arr(curr_dim+1) for [0...counts[curr_dim]])
    rs.push init_arr 0

class root.ArrayLoadOpcode extends root.Opcode
  constructor: (name, params) ->
    super name, params
    @in = [1,1]
    @out = if @name.match /[ld]aload/ then [2] else [1]

  compile: ->
    """
    var array = rs.get_obj(in0).array;
    var idx = in1;
    if (!(0 <= idx && idx < array.length))
      java_throw(rs, 'java/lang/ArrayIndexOutOfBoundsException', idx + " not in [0, " + array.length + ")")
    out0 = array[idx];
    """

class root.ArrayStoreOpcode extends root.Opcode
  compile: -> "rs.get_obj(in0).array[in1]=in2;"

towards_zero = (a) ->
  Math[if a > 0 then 'floor' else 'ceil'](a)

int_mod = (rs, a, b) ->
  java_throw rs, 'java/lang/ArithmeticException', '/ by zero' if b == 0
  a % b

int_div = (rs, a, b) ->
  java_throw rs, 'java/lang/ArithmeticException', '/ by zero' if b == 0
  towards_zero a / b
  # TODO spec: "if the dividend is the negative integer of largest possible magnitude
  # for the int type, and the divisor is -1, then overflow occurs, and the
  # result is equal to the dividend."

long_mod = (rs, a, b) ->
  java_throw rs, 'java/lang/ArithmeticException', '/ by zero' if b.isZero()
  a.modulo(b)

long_div = (rs, a, b) ->
  java_throw rs, 'java/lang/ArithmeticException', '/ by zero' if b.isZero()
  a.div(b)

float2int = (a) ->
  INT_MAX = Math.pow(2, 31) - 1
  INT_MIN = - Math.pow 2, 31
  if a == NaN then 0
  else if a > INT_MAX then INT_MAX  # these two cases handle d2i issues
  else if a < INT_MIN then INT_MIN
  else unless a == Infinity or a == -Infinity then towards_zero a
  else if a > 0 then INT_MAX
  else INT_MIN

# sign-preserving number truncate, with overflow and such
truncate = (a, n_bits) ->
  a = (a + Math.pow 2, n_bits) % Math.pow 2, n_bits
  util.uint2int a, n_bits/8

wrap_int = (a) -> truncate a, 32

wrap_float = (a) ->
  return Infinity if a > 3.40282346638528860e+38
  return 0 if 0 < a < 1.40129846432481707e-45
  return -Infinity if a < -3.40282346638528860e+38
  return 0 if 0 > a > -1.40129846432481707e-45
  a

jsr = (rs) ->
  rs.push(rs.curr_pc()+@byte_count+1); throw new BranchException rs.curr_pc() + @offset

# these objects are used as prototypes for the parsed instructions in the
# classfile
root.opcodes = {
  0: new root.Opcode 'nop', { compile:->'' }
  1: new root.Opcode 'aconst_null', { out:[1], compile:->'out0=0;' }
  2: new root.Opcode 'iconst_m1', { out:[1], compile:->'out0=-1;' }
  3: new root.Opcode 'iconst_0', { out:[1], compile:->'out0=0;' }
  4: new root.Opcode 'iconst_1', { out:[1], compile:->'out0=1;' }
  5: new root.Opcode 'iconst_2', { out:[1], compile:->'out0=2;' }
  6: new root.Opcode 'iconst_3', { out:[1], compile:->'out0=3;' }
  7: new root.Opcode 'iconst_4', { out:[1], compile:->'out0=4;' }
  8: new root.Opcode 'iconst_5', { out:[1], compile:->'out0=5;' }
  9: new root.Opcode 'lconst_0', { out:[2], compile:->'out0=gLong.ZERO;' }
  10: new root.Opcode 'lconst_1', { out:[2], compile:->'out0=gLong.ONE;' }
  11: new root.Opcode 'fconst_0', { out:[1], compile:->'out0=0;' }
  12: new root.Opcode 'fconst_1', { out:[1], compile:->'out0=1;' }
  13: new root.Opcode 'fconst_2', { out:[1], compile:->'out0=2;' }
  14: new root.Opcode 'dconst_0', { out:[2], compile:->'out0=0;' }
  15: new root.Opcode 'dconst_1', { out:[2], compile:->'out0=1;' }
  16: new root.PushOpcode 'bipush', { byte_count: 1 }
  17: new root.PushOpcode 'sipush', { byte_count: 2 }
  18: new root.LoadConstantOpcode 'ldc', { byte_count: 1 }
  19: new root.LoadConstantOpcode 'ldc_w', { byte_count: 2 }
  20: new root.LoadConstantOpcode 'ldc2_w', { byte_count: 2 }
  21: new root.LoadVarOpcode 'iload'
  22: new root.LoadVarOpcode 'lload'
  23: new root.LoadVarOpcode 'fload'
  24: new root.LoadVarOpcode 'dload'
  25: new root.LoadVarOpcode 'aload'
  26: new root.LoadOpcode 'iload_0'
  27: new root.LoadOpcode 'iload_1'
  28: new root.LoadOpcode 'iload_2'
  29: new root.LoadOpcode 'iload_3'
  30: new root.LoadOpcode 'lload_0'
  31: new root.LoadOpcode 'lload_1'
  32: new root.LoadOpcode 'lload_2'
  33: new root.LoadOpcode 'lload_3'
  34: new root.LoadOpcode 'fload_0'
  35: new root.LoadOpcode 'fload_1'
  36: new root.LoadOpcode 'fload_2'
  37: new root.LoadOpcode 'fload_3'
  38: new root.LoadOpcode 'dload_0'
  39: new root.LoadOpcode 'dload_1'
  40: new root.LoadOpcode 'dload_2'
  41: new root.LoadOpcode 'dload_3'
  42: new root.LoadOpcode 'aload_0'
  43: new root.LoadOpcode 'aload_1'
  44: new root.LoadOpcode 'aload_2'
  45: new root.LoadOpcode 'aload_3'
  46: new root.ArrayLoadOpcode 'iaload'
  47: new root.ArrayLoadOpcode 'laload'
  48: new root.ArrayLoadOpcode 'faload'
  49: new root.ArrayLoadOpcode 'daload'
  50: new root.ArrayLoadOpcode 'aaload'
  51: new root.ArrayLoadOpcode 'baload'
  52: new root.ArrayLoadOpcode 'caload'
  53: new root.ArrayLoadOpcode 'saload'
  54: new root.StoreVarOpcode 'istore'
  55: new root.StoreVarOpcode 'lstore'
  56: new root.StoreVarOpcode 'fstore'
  57: new root.StoreVarOpcode 'dstore'
  58: new root.StoreVarOpcode 'astore'
  59: new root.StoreOpcode 'istore_0'
  60: new root.StoreOpcode 'istore_1'
  61: new root.StoreOpcode 'istore_2'
  62: new root.StoreOpcode 'istore_3'
  63: new root.StoreOpcode 'lstore_0'
  64: new root.StoreOpcode 'lstore_1'
  65: new root.StoreOpcode 'lstore_2'
  66: new root.StoreOpcode 'lstore_3'
  67: new root.StoreOpcode 'fstore_0'
  68: new root.StoreOpcode 'fstore_1'
  69: new root.StoreOpcode 'fstore_2'
  70: new root.StoreOpcode 'fstore_3'
  71: new root.StoreOpcode 'dstore_0'
  72: new root.StoreOpcode 'dstore_1'
  73: new root.StoreOpcode 'dstore_2'
  74: new root.StoreOpcode 'dstore_3'
  75: new root.StoreOpcode 'astore_0'
  76: new root.StoreOpcode 'astore_1'
  77: new root.StoreOpcode 'astore_2'
  78: new root.StoreOpcode 'astore_3'
  79: new root.ArrayStoreOpcode 'iastore', { in:[1,1,1] }
  80: new root.ArrayStoreOpcode 'lastore', { in:[1,1,2] }
  81: new root.ArrayStoreOpcode 'fastore', { in:[1,1,1] }
  82: new root.ArrayStoreOpcode 'dastore', { in:[1,1,2] }
  83: new root.ArrayStoreOpcode 'aastore', { in:[1,1,1] }
  84: new root.ArrayStoreOpcode 'bastore', { in:[1,1,1] }
  85: new root.ArrayStoreOpcode 'castore', { in:[1,1,1] }
  86: new root.ArrayStoreOpcode 'sastore', { in:[1,1,1] }
  87: new root.Opcode 'pop', { in: [1] }
  88: new root.Opcode 'pop2', { in: [2] }
  89: new root.Opcode 'dup', {in:[1],out:[1,1],compile:->"out0=out1=in0;"}
  90: new root.Opcode 'dup_x1', {in:[1,1],out:[1,1,1],compile:->"out1=in0;out0=out2=in1;"}
  91: new root.Opcode 'dup_x2', {in:[1,1,1],out:[1,1,1,1],compile:->"out0=out3=in2;out1=in0;out2=in1;"}
  92: new root.Opcode 'dup2', {in:[1,1],out:[1,1,1,1],compile:->"out0=out2=in0;out1=out3=in1;"}
  93: new root.Opcode 'dup2_x1', {in:[1,1,1],out:[1,1,1,1,1],compile:->"out0=out3=in1;out1=out4=in2;out2=in0;"}
  94: new root.Opcode 'dup2_x2', {in:[1,1,1,1],out:[1,1,1,1,1,1],compile:->"out0=out4=in2;out1=out5=in3;out2=in0;out3=in1;"}
  95: new root.Opcode 'swap', {in:[1,1],out:[1,1],compile:->"out0=in1;out1=in0;"}
  96: new root.Opcode 'iadd', {in:[1,1],out:[1],compile:->'out0=wrap_int(in0+in1);'}
  97: new root.Opcode 'ladd', {in:[2,2],out:[2],compile:->'out0=in0.add(in1);'}
  98: new root.Opcode 'fadd', {in:[1,1],out:[1],compile:->'out0=wrap_float(in0+in1);'}
  99: new root.Opcode 'dadd', {in:[2,2],out:[2],compile:->'out0=in0+in1;'}
  100: new root.Opcode 'isub', {in:[1,1],out:[1],compile:->"out0=wrap_int(in0-in1);"}
  101: new root.Opcode 'lsub', {in:[2,2],out:[2],compile:->'out0=in0.add(in1.negate());'}
  102: new root.Opcode 'fsub', {in:[1,1],out:[1],compile:->"out0=wrap_float(in0-in1);"}
  103: new root.Opcode 'dsub', {in:[2,2],out:[2],compile:->"out0=in0-in1;"}
  104: new root.Opcode 'imul', {in:[1,1],out:[1],compile:->"out0=gLong.fromInt(in0).multiply(gLong.fromInt(in1)).toInt();"}
  105: new root.Opcode 'lmul', {in:[2,2],out:[2],compile:->"out0=in0.multiply(in1);"}
  106: new root.Opcode 'fmul', {in:[1,1],out:[1],compile:->"out0=wrap_float(in0*in1);"}
  107: new root.Opcode 'dmul', {in:[2,2],out:[2],compile:->"out0=in0*in1;"}
  108: new root.Opcode 'idiv', {in:[1,1],out:[1],compile:->"out0=int_div(rs,in0,in1);"}
  109: new root.Opcode 'ldiv', {in:[2,2],out:[2],compile:->"out0=long_div(rs,in0,in1);"}
  110: new root.Opcode 'fdiv', {in:[1,1],out:[1],compile:->"out0=wrap_float(in0/in1);"}
  111: new root.Opcode 'ddiv', {in:[2,2],out:[2],compile:->"out0=in0/in1;"}
  112: new root.Opcode 'irem', {in:[1,1],out:[1],compile:->"out0=int_mod(rs,in0,in1);"}
  113: new root.Opcode 'lrem', {in:[2,2],out:[2],compile:->"out0=long_mod(rs,in0,in1);"}
  114: new root.Opcode 'frem', {in:[1,1],out:[1],compile:->"out0=in0%in1;"}
  115: new root.Opcode 'drem', {in:[2,2],out:[2],compile:->"out0=in0%in1;"}
  116: new root.Opcode 'ineg', {in:[1],out:[1],compile:->"out0=-in0;"}
  117: new root.Opcode 'lneg', {in:[2],out:[2],compile:->"out0=in0.negate();"}
  118: new root.Opcode 'fneg', {in:[1],out:[1],compile:->"out0=-in0;"}
  119: new root.Opcode 'dneg', {in:[2],out:[2],compile:->"out0=-in0;"}
  120: new root.Opcode 'ishl', {in:[1,1],out:[1],compile:->"out0=in0<<(in1&0x1F);"}
  121: new root.Opcode 'lshl', {in:[2,1],out:[2],compile:->"out0=in0.shiftLeft(gLong.fromInt(in1&0x3F));"}
  122: new root.Opcode 'ishr', {in:[1,1],out:[1],compile:->"out0=in0>>in1;"}
  123: new root.Opcode 'lshr', {in:[2,1],out:[2],compile:->"out0=in0.shiftRight(gLong.fromInt(in1&0x3F));"}
  124: new root.Opcode 'iushr', {in:[1,1],out:[1],compile:->"out0=in0>>>in1;"}
  125: new root.Opcode 'lushr', {in:[2,1],out:[2],compile:->"out0=in0.shiftRightUnsigned(gLong.fromInt(in1&0x3F));"}
  126: new root.Opcode 'iand', {in:[1,1],out:[1],compile:->"out0=in0&in1;"}
  127: new root.Opcode 'land', {in:[2,2],out:[2],compile:->"out0=in0.and(in1);"}
  128: new root.Opcode 'ior', {in:[1,1],out:[1],compile:->"out0=in0|in1;"}
  129: new root.Opcode 'lor', {in:[2,2],out:[2],compile:->"out0=in0.or(in1);"}
  130: new root.Opcode 'ixor', {in:[1,1],out:[1],compile:->"out0=in0^in1;"}
  131: new root.Opcode 'lxor',{in:[2,2],out:[2],compile:->"out0=in0.xor(in1);"}
  132: new root.IIncOpcode 'iinc'
  133: new root.Opcode 'i2l', {in:[1],out:[2],compile:->"out0=gLong.fromNumber(in0)"}
  134: new root.Opcode 'i2f', {compile:->''}
  135: new root.Opcode 'i2d', {in:[1],out:[2],compile:->"out0=in0;"}
  136: new root.Opcode 'l2i', {in:[2],out:[1],compile:->"out0=in0.toInt();"}
  137: new root.Opcode 'l2f', {in:[2],out:[1],compile:->"out0=in0.toNumber();"}
  138: new root.Opcode 'l2d', {in:[2],out:[2],compile:->"out0=in0.toNumber();"}
  139: new root.Opcode 'f2i', {in:[1],out:[1],compile:->"out0=float2int(in0);"}
  140: new root.Opcode 'f2l', {in:[1],out:[2],compile:->"out0=gLong.fromNumber(in0);"}
  141: new root.Opcode 'f2d', {in:[1],out:[2],compile:->"out0=in0;"}
  142: new root.Opcode 'd2i', {in:[2],out:[1],compile:->"out0=float2int(in0);"}
  143: new root.Opcode 'd2l', {in:[2],out:[2],compile:->"out0=gLong.fromNumber(in0);"}
  144: new root.Opcode 'd2f', {in:[2],out:[1],compile:->"out0=wrap_float(in0);"}
  145: new root.Opcode 'i2b', {in:[1],out:[1],compile:->"out0=truncate(in0,8);"}
  146: new root.Opcode 'i2c', {in:[1],out:[1],compile:->"out0=truncate(in0,8);"}
  147: new root.Opcode 'i2s', {in:[1],out:[1],compile:->"out0=truncate(in0,16);"}
  148: new root.Opcode 'lcmp', {in:[2,2],out:[1],compile:->"out0=in0.compare(in1);"}
  149: new root.Opcode 'fcmpl', {in:[1,1],out:[1],compile:->"var rv=util.cmp(in0,in1);out0=rv===null ? -1 : rv;"}
  150: new root.Opcode 'fcmpg', {in:[1,1],out:[1],compile:->"var rv=util.cmp(in0,in1);out0=rv===null ? 1 : rv;"}
  151: new root.Opcode 'dcmpl', {in:[2,2],out:[1],compile:->"var rv=util.cmp(in0,in1);out0=rv===null ? -1 : rv;"}
  152: new root.Opcode 'dcmpg', {in:[2,2],out:[1],compile:->"var rv=util.cmp(in0,in1);out0=rv===null ? 1 : rv;"}
  153: new root.UnaryBranchOpcode 'ifeq', { cmp: (v) -> v == 0 }
  154: new root.UnaryBranchOpcode 'ifne', { cmp: (v) -> v != 0 }
  155: new root.UnaryBranchOpcode 'iflt', { cmp: (v) -> v < 0 }
  156: new root.UnaryBranchOpcode 'ifge', { cmp: (v) -> v >= 0 }
  157: new root.UnaryBranchOpcode 'ifgt', { cmp: (v) -> v > 0 }
  158: new root.UnaryBranchOpcode 'ifle', { cmp: (v) -> v <= 0 }
  159: new root.BinaryBranchOpcode 'if_icmpeq', { cmp: (v1, v2) -> v1 == v2 }
  160: new root.BinaryBranchOpcode 'if_icmpne', { cmp: (v1, v2) -> v1 != v2 }
  161: new root.BinaryBranchOpcode 'if_icmplt', { cmp: (v1, v2) -> v1 < v2 }
  162: new root.BinaryBranchOpcode 'if_icmpge', { cmp: (v1, v2) -> v1 >= v2 }
  163: new root.BinaryBranchOpcode 'if_icmpgt', { cmp: (v1, v2) -> v1 > v2 }
  164: new root.BinaryBranchOpcode 'if_icmple', { cmp: (v1, v2) -> v1 <= v2 }
  165: new root.BinaryBranchOpcode 'if_acmpeq', { cmp: (v1, v2) -> v1 == v2 }
  166: new root.BinaryBranchOpcode 'if_acmpne', { cmp: (v1, v2) -> v1 != v2 }
  167: new root.BranchOpcode 'goto', { execute: (rs) -> throw new BranchException rs.curr_pc() + @offset }
  168: new root.BranchOpcode 'jsr', { execute: jsr }
  169: new root.Opcode 'ret', { byte_count: 1, execute: (rs) -> throw new BranchException rs.cl @args[0] }
  170: new root.TableSwitchOpcode 'tableswitch'
  171: new root.LookupSwitchOpcode 'lookupswitch'
  172: new root.Opcode 'ireturn', { execute: (rs) -> throw new ReturnException rs.curr_frame().stack[0] }
  173: new root.Opcode 'lreturn', { execute: (rs) -> throw new ReturnException rs.curr_frame().stack[0], null }
  174: new root.Opcode 'freturn', { execute: (rs) -> throw new ReturnException rs.curr_frame().stack[0] }
  175: new root.Opcode 'dreturn', { execute: (rs) -> throw new ReturnException rs.curr_frame().stack[0], null }
  176: new root.Opcode 'areturn', { execute: (rs) -> throw new ReturnException rs.curr_frame().stack[0] }
  177: new root.Opcode 'return', { execute: (rs) -> throw new ReturnException }
  178: new root.FieldOpcode 'getstatic', { compile:->
    @out = if @field_spec.type in ['J','D'] then [2] else [1]
    "out0=rs.static_get(#{JSON.stringify @field_spec});" }
  179: new root.FieldOpcode 'putstatic', {compile:->
    @in = if @field_spec.type in ['J','D'] then [2] else [1]
    "rs.static_put(#{JSON.stringify @field_spec}, in0);" }
  180: new root.FieldOpcode 'getfield', {in:[1],compile:->
    @out = if @field_spec.type in 'JD' then [2] else [1]
    "out0=rs.heap_get(#{JSON.stringify @field_spec},in0);"}
  181: new root.FieldOpcode 'putfield', {compile:->
    @in = if @field_spec.type in ['J','D'] then [1,2] else [1,1]
    "rs.heap_put(#{JSON.stringify @field_spec},in0,in1);"}
  182: new root.InvokeOpcode 'invokevirtual',  { execute: (rs)-> rs.method_lookup(@method_spec).run(rs,true)}
  183: new root.InvokeOpcode 'invokespecial',  { execute: (rs)-> rs.method_lookup(@method_spec).run(rs)}
  184: new root.InvokeOpcode 'invokestatic',   { execute: (rs)-> rs.method_lookup(@method_spec).run(rs)}
  185: new root.InvokeOpcode 'invokeinterface',{ execute: (rs)-> rs.method_lookup(@method_spec).run(rs,true)}
  187: new root.ClassOpcode 'new', { execute: (rs) -> rs.push rs.init_object @class }
  188: new root.NewArrayOpcode 'newarray', { execute: (rs) -> rs.push rs.heap_newarray @element_type, rs.pop() }
  189: new root.ClassOpcode 'anewarray', { execute: (rs) -> rs.push rs.heap_newarray "L#{@class};", rs.pop() }
  190: new root.Opcode 'arraylength', { execute: (rs) -> rs.push rs.get_obj(rs.pop()).array.length }
  191: new root.Opcode 'athrow', { execute: (rs) -> throw new JavaException rs, rs.pop() }
  192: new root.ClassOpcode 'checkcast', { execute: (rs) ->
    o = rs.pop()
    if o == 0 or rs.check_cast(o,@class)
      rs.push o
    else
      target_class = c2t(@class).toExternalString() # class we wish to cast to
      candidate_class = if o != 0 then rs.get_obj(o).type.toExternalString() else "null"
      java_throw rs, 'java/lang/ClassCastException', "#{candidate_class} cannot be cast to #{target_class}"
  }
  193: new root.ClassOpcode 'instanceof', { execute: (rs) -> o=rs.pop(); rs.push if o>0 then rs.check_cast(o,@class)+0 else 0 }
  194: new root.Opcode 'monitorenter', {in:[1],compile:->''}  #TODO: actually implement locks?
  195: new root.Opcode 'monitorexit',  {in:[1],compile:->''}  #TODO: actually implement locks?
  197: new root.MultiArrayOpcode 'multianewarray'
  198: new root.UnaryBranchOpcode 'ifnull', { cmp: (v) -> v <= 0 }
  199: new root.UnaryBranchOpcode 'ifnonnull', { cmp: (v) -> v > 0 }
  200: new root.BranchOpcode 'goto_w', { byte_count: 4, execute: (rs) -> throw new BranchException rs.curr_pc() + @offset }
  201: new root.BranchOpcode 'jsr_w', { byte_count: 4, execute: jsr }
}


root.parse_cmd = (op) ->
  cmd = op.compile?() or ""
  _in = op.in ? []
  _out = op.out ? []
  fn_args = ['rs']
  prologue =
    (for idx in [_in.length-1..0] by -1
      size = _in[idx]
      if size == 1 then "var in#{idx} = rs.pop();"
      else "var in#{idx} = rs.pop2();").join ''
  prologue += ("var out#{i};" for i in [0..._out.length] by 1).join ''
  cmd = (cmd.replace /@/g, 'this.') ? ''
  lines = cmd.split('\n')
  for idx in [0..._out.length] by 1
    size = _out[idx]
    if size == 1 then lines.push "rs.push(out#{idx})"
    else lines.push "rs.push(out#{idx}, null)"
  cmd = lines.join '\n'
  eval "(function (#{fn_args}) { #{prologue} #{cmd} })"
