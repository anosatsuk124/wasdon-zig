#!/usr/bin/env python3
"""Emit the Udon Assembly UdonSharp 1.x generates for UdonBench.cs.

Each helper mirrors one emit routine of the UdonSharp compiler
(Packages/com.vrchat.UdonSharp/Editor/Compiler): one EXTERN per operator
with the assignment target as result slot, PUSH/COPY/JUMP_INDIRECT returns,
the return-address push at every method entry, and the recursive-method
stack protocol of BoundUserMethodInvocation.
"""
import sys

I32 = "SystemInt32"
OPS = {"+": "Addition", "-": "Subtraction", "*": "Multiplication", "/": "Division",
       "<": "LessThan", ">": "GreaterThan", ">=": "GreaterThanOrEqual", "<=": "LessThanOrEqual",
       "==": "Equality"}
FIELDS = {"fibN": 20, "fibResult": 0, "mandelResult": 0, "strResult": 0,
          "takX": 8, "takY": 4, "takZ": 0, "takResult": 0, "ackM": 3, "ackN": 4, "ackResult": 0}

class Gen:
    def __init__(self):
        self.code = []      # (kind, payload)
        self.vars = {}      # name -> (type, init)
        self.addr = 0
        self.labels = {}
        self.fix = []       # (var name, label) return-address constants
        self.n = {}

    def var(self, name, ty, init="null"):
        self.vars.setdefault(name, (ty, init))
        return name

    def new(self, prefix, ty, init="null"):
        k = self.n.get((prefix, ty), 0)
        self.n[(prefix, ty)] = k + 1
        return self.var(f"__{prefix}_{ty}_{k}", ty, init)

    def const(self, value, ty=I32):
        name = f"__const_{ty}_{str(value).replace('-', 'n')}" if ty != "SystemString" else f"__const_SystemString_{len([v for v in self.vars if v.startswith('__const_SystemString')])}"
        if ty == "SystemString":
            for n, (t, init) in self.vars.items():
                if t == ty and init == f'"{value}"':
                    return n
            return self.var(name, ty, f'"{value}"')
        return self.var(name, ty, str(value))

    def emit(self, text, size):
        self.code.append(text)
        self.addr += size

    def comment(self, text):
        self.code.append(f"# {text}")

    def push(self, v): self.emit(f"PUSH, {v}", 8)
    def copy(self, src, dst):
        self.push(src); self.push(dst); self.emit("COPY", 4)
    def extern(self, sig, *operands):
        for o in operands: self.push(o)
        self.emit(f'EXTERN, "{sig}"', 8)
    def op(self, op, a, b, dst, ty=I32):
        ret = "SystemBoolean" if op in ("<", ">", ">=", "<=", "==") else ty
        self.extern(f"{ty}.__op_{OPS[op]}__{ty}_{ty}__{ret}", a, b, dst)
        return dst
    def label(self, name):
        self.labels[name] = self.addr
        self.code.append(("label", name))
    def jump(self, label): self.emit(("JUMP", label), 8)
    def jif(self, cond, label):
        self.push(cond); self.emit(("JUMP_IF_FALSE", label), 8)
    def ret(self):
        r = "__intnl_returnJump_SystemUInt32_0"
        self.var(r, "SystemUInt32", "0")
        self.push(r); self.emit("COPY", 4); self.emit(f"JUMP_INDIRECT, {r}", 8)

    def method(self, name, export):
        if export:
            self.code.append(("export", name))
            self.label(name)
        # UdonSharpBehaviourMethodSymbol.Emit: the exit address for a call
        # from outside; internal calls jump past it.
        self.push(self.var("__const_SystemUInt32_0", "SystemUInt32", "0xFFFFFFFF"))
        self.label(name + "__body")

    def return_point(self):
        v = self.new("gintnl", "SystemUInt32", None)
        self.push(v)
        return v

    def land(self, v):
        name = f"ret_{v}"
        self.label(name)
        self.fix.append((v, name))

    def render(self, out):
        for v, label in self.fix:
            ty, _ = self.vars[v]
            self.vars[v] = (ty, f"0x{self.labels[label]:08X}")
        out.write(".data_start\n")
        for name in FIELDS:
            out.write(f"    .export {name}\n")
        for name, (ty, init) in self.vars.items():
            out.write(f"    {name}: %{ty}, {init}\n")
        out.write(".data_end\n.code_start\n")
        for c in self.code:
            if isinstance(c, tuple):
                if c[0] == "label":
                    out.write(f"    {c[1]}:\n")
                elif c[0] == "export":
                    out.write(f"    .export {c[1]}\n")
                else:
                    out.write(f"        {c[0]}, 0x{self.labels[c[1]]:08X}\n")
            elif c.startswith("#"):
                out.write(f"        {c}\n")
            else:
                out.write(f"        {c}\n")
        out.write(".code_end\n")

g = Gen()
for f, default in FIELDS.items():
    g.var(f, I32, str(default))
STACK = g.var("__gintnl_SystemObjectArray_0", "SystemObjectArray")
SP = g.var("__gintnl_SystemInt32_0", I32, "0")
c = g.const

# ---------------------------------------------------------------- Fib()
g.method("Fib", True)
g.comment("fibResult = FibRec(fibN);")
n = g.var("__0_n__param", I32, "0")
fib_ret = g.var("__0_FibRec__ret", I32, "0")
rp = g.return_point()
g.copy("fibN", n)
g.jump("FibRec__body")
g.land(rp)
g.copy(fib_ret, "fibResult")
g.ret()

# ------------------------------------------------------ FibRec(int n)
def stack_check(count):
    """BoundInvocationExpression.CheckStackSize"""
    g.comment("stack size check")
    size = g.new("intnl", I32, "0")
    g.extern("SystemArray.__get_Length__SystemInt32", STACK, size)
    target = g.new("intnl", I32, "0")
    g.op("+", SP, c(count), target)
    grow = g.new("intnl", "SystemBoolean")
    g.op(">=", target, size, grow)
    skip = f"skip_resize_{g.addr}"
    g.jif(grow, skip)
    new_size = g.new("intnl", I32, "0")
    g.op("*", size, c(2), new_size)
    new_array = g.new("intnl", "SystemObjectArray")
    g.extern("SystemObjectArray.__ctor__SystemInt32__SystemObjectArray", new_size, new_array)
    g.extern("SystemArray.__Copy__SystemArray_SystemArray_SystemInt32__SystemVoid", STACK, new_array, size)
    g.copy(new_array, STACK)
    g.label(skip)

def push_values(values):
    g.comment("recursive stack push")
    for v in values:
        g.extern("SystemObjectArray.__Set__SystemInt32_SystemObject__SystemVoid", STACK, SP, v)
        g.op("+", SP, c(1), SP)

def pop_values(values):
    g.comment("recursive stack pop")
    for v in reversed(values):
        g.op("-", SP, c(1), SP)
        g.extern("SystemObjectArray.__Get__SystemInt32__SystemObject", STACK, SP, v)

def recursive_call(arg_op, held):
    """BoundUserMethodInvocation.EmitValue inside a [RecursiveMethod]:
    `held` are values the caller keeps across the call besides `n`."""
    rp = g.return_point()
    arg = g.new("intnl", I32, "0")
    g.op("-", n, c(arg_op), arg)
    stack_check(1 + len(held))
    push_values([n])
    g.copy(arg, n)
    push_values(held)
    g.jump("FibRec__body")
    g.land(rp)
    result = g.new("intnl", I32, "0")
    g.copy(fib_ret, result)
    pop_values([n] + held)
    return result

g.method("FibRec", False)
g.comment("if (n < 2) return n;")
lt = g.new("intnl", "SystemBoolean")
g.op("<", n, c(2), lt)
g.jif(lt, "fib_recurse")
g.copy(n, fib_ret)
g.ret()
g.label("fib_recurse")
g.comment("return FibRec(n - 1) + FibRec(n - 2);")
a = recursive_call(1, [])
b = recursive_call(2, [a])
g.op("+", a, b, fib_ret)
g.ret()

# -------------------------------------------------------------- Mandel()
g.method("Mandel", True)
L = lambda name: g.var(f"__0_{name}__local", I32, "0")
total, h, w, max_iter, py, px = map(L, ("total", "h", "w", "maxIter", "py", "px"))
x0, y0, x, y, it, xx, yy, xy = map(L, ("x0", "y0", "x", "y", "it", "xx", "yy", "xy"))
t = lambda: g.new("intnl", I32, "0")
tb = lambda: g.new("intnl", "SystemBoolean")
g.comment("int total = 0; int h = 8; int w = 16; int maxIter = 24; int py = 0;")
g.copy(c(0), total); g.copy(c(8), h); g.copy(c(16), w); g.copy(c(24), max_iter); g.copy(c(0), py)
g.label("m_py"); g.comment("while (py < h)")
g.jif(g.op("<", py, h, tb()), "m_py_end")
g.comment("int px = 0;")
g.copy(c(0), px)
g.label("m_px"); g.comment("while (px < w)")
g.jif(g.op("<", px, w, tb()), "m_px_end")
g.comment("int x0 = (px * 3072 / w) - 2048;")
g.op("-", g.op("/", g.op("*", px, c(3072), t()), w, t()), c(2048), x0)
g.comment("int y0 = (py * 2048 / h) - 1024;")
g.op("-", g.op("/", g.op("*", py, c(2048), t()), h, t()), c(1024), y0)
g.comment("int x = 0; int y = 0; int it = 0;")
g.copy(c(0), x); g.copy(c(0), y); g.copy(c(0), it)
g.label("m_it"); g.comment("while (it < maxIter)")
g.jif(g.op("<", it, max_iter, tb()), "m_it_end")
g.comment("int xx = (x * x) / 1024;")
g.op("/", g.op("*", x, x, t()), c(1024), xx)
g.comment("int yy = (y * y) / 1024;")
g.op("/", g.op("*", y, y, t()), c(1024), yy)
g.comment("if (xx + yy > 4096) break;")
g.jif(g.op(">", g.op("+", xx, yy, t()), c(4096), tb()), "m_no_break")
g.jump("m_it_end")
g.label("m_no_break")
g.comment("int xy = (x * y) / 1024;")
g.op("/", g.op("*", x, y, t()), c(1024), xy)
g.comment("x = xx - yy + x0;")
g.op("+", g.op("-", xx, yy, t()), x0, x)
g.comment("y = 2 * xy + y0;")
g.op("+", g.op("*", c(2), xy, t()), y0, y)
g.comment("it += 1;")
g.op("+", it, c(1), it)
g.jump("m_it")
g.label("m_it_end")
g.comment("total += it; px += 1;")
g.op("+", total, it, total)
g.op("+", px, c(1), px)
g.jump("m_px")
g.label("m_px_end")
g.comment("py += 1;")
g.op("+", py, c(1), py)
g.jump("m_py")
g.label("m_py_end")
g.comment("mandelResult = total;")
g.copy(total, "mandelResult")
g.ret()

# ----------------------------------------------------------------- Str()
g.method("Str", True)
s = g.var("__0_s__local", "SystemString")
i = L("i")
g.comment('string s = ""; int i = 0;')
g.copy(c("", "SystemString"), s); g.copy(c(0), i)
g.label("s_loop"); g.comment("while (i < 64)")
g.jif(g.op("<", i, c(64), tb()), "s_end")
g.comment('s += "abc"; i += 1;')
g.extern("SystemString.__Concat__SystemString_SystemString__SystemString", s, c("abc", "SystemString"), s)
g.op("+", i, c(1), i)
g.jump("s_loop")
g.label("s_end")
g.comment("strResult = s.Length;")
g.extern("SystemString.__get_Length__SystemInt32", s, "strResult")
g.ret()

# ------------------------------------------- recursion with several parameters
def call_recursive(rp, method, params, ret, args, held):
    """BoundUserMethodInvocation.EmitValue inside a [RecursiveMethod], after
    the return point `rp` has been pushed and the arguments evaluated into
    `args`. `held` are the values that still have an open reference — the
    results of the earlier arguments of an enclosing call."""
    stack_check(len(params) + len(held))
    push_values(params)
    # An argument that is itself a parameter is read before any parameter
    # is overwritten (U#'s copy-on-write values).
    sources = []
    for a in args:
        if a in params:
            keep = g.new("intnl", I32, "0")
            g.copy(a, keep)
            a = keep
        sources.append(a)
    for a, p in zip(sources, params):
        g.copy(a, p)
    push_values(held)
    g.jump(method + "__body")
    g.land(rp)
    result = g.new("intnl", I32, "0")
    g.copy(ret, result)
    pop_values(params + held)
    return result

# ---------------------------------------------------------------- Tak()
g.method("Tak", True)
g.comment("takResult = TakRec(takX, takY, takZ);")
tx, ty, tz = (g.var(f"__0_{v}__param", I32, "0") for v in ("x", "y", "z"))
tak_ret = g.var("__0_TakRec__ret", I32, "0")
rp = g.return_point()
g.copy("takX", tx); g.copy("takY", ty); g.copy("takZ", tz)
g.jump("TakRec__body")
g.land(rp)
g.copy(tak_ret, "takResult")
g.ret()

# ------------------------------------------- TakRec(int x, int y, int z)
g.method("TakRec", False)
g.comment("if (x <= y) return y;")
g.jif(g.op("<=", tx, ty, tb()), "tak_recurse")
g.copy(ty, tak_ret)
g.ret()
g.label("tak_recurse")
g.comment("return TakRec(TakRec(x - 1, y, z), TakRec(y - 1, z, x), TakRec(z - 1, x, y));")
TAK = [tx, ty, tz]
outer = g.return_point()
rp = g.return_point()
r1 = call_recursive(rp, "TakRec", TAK, tak_ret, [g.op("-", tx, c(1), t()), ty, tz], [])
rp = g.return_point()
r2 = call_recursive(rp, "TakRec", TAK, tak_ret, [g.op("-", ty, c(1), t()), tz, tx], [r1])
rp = g.return_point()
r3 = call_recursive(rp, "TakRec", TAK, tak_ret, [g.op("-", tz, c(1), t()), tx, ty], [r1, r2])
g.copy(call_recursive(outer, "TakRec", TAK, tak_ret, [r1, r2, r3], []), tak_ret)
g.ret()

# ---------------------------------------------------------------- Ack()
g.method("Ack", True)
g.comment("ackResult = AckRec(ackM, ackN);")
am, an = (g.var(f"__0_{v}__param", I32, "0") for v in ("m", "n"))
ack_ret = g.var("__0_AckRec__ret", I32, "0")
rp = g.return_point()
g.copy("ackM", am); g.copy("ackN", an)
g.jump("AckRec__body")
g.land(rp)
g.copy(ack_ret, "ackResult")
g.ret()

# --------------------------------------------------- AckRec(int m, int n)
g.method("AckRec", False)
ACK = [am, an]
g.comment("if (m == 0) return n + 1;")
g.jif(g.op("==", am, c(0), tb()), "ack_m")
g.op("+", an, c(1), ack_ret)
g.ret()
g.label("ack_m")
g.comment("if (n == 0) return AckRec(m - 1, 1);")
g.jif(g.op("==", an, c(0), tb()), "ack_n")
rp = g.return_point()
g.copy(call_recursive(rp, "AckRec", ACK, ack_ret, [g.op("-", am, c(1), t()), c(1)], []), ack_ret)
g.ret()
g.label("ack_n")
g.comment("return AckRec(m - 1, AckRec(m, n - 1));")
outer = g.return_point()
m1 = g.op("-", am, c(1), t())
rp = g.return_point()
inner = call_recursive(rp, "AckRec", ACK, ack_ret, [am, g.op("-", an, c(1), t())], [m1])
g.copy(call_recursive(outer, "AckRec", ACK, ack_ret, [m1, inner], []), ack_ret)
g.ret()

g.render(sys.stdout)
