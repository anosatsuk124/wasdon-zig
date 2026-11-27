import os
import sys
sys.path.insert(0, os.environ["WASDON_SDK"])
from official import main, params, project_inputs, run, symbol, tool


def declaration(node):
    args, ret = params(node)
    return f"fn {symbol(node)}({', '.join('p' + str(i) + ': ' + t for i,t in enumerate(args))}) {ret or 'void'}"


def generate(nodes, dest):
    with (dest / "raw.zig").open("w", encoding="utf-8", newline="\n") as f:
        for n in nodes:
            args, ret = params(n)
            f.write(f'pub const {symbol(n)} = @extern(*const fn ({", ".join(args)}) callconv(.c) {ret or "void"}, .{{ .name = "{n["name"]}", .library_name = "wasdon.v1" }});\n')


def compile_project(project, out):
    flags = ["-target", "wasm32-freestanding", "-mcpu=mvp", "-OReleaseSmall"]
    run([tool("zig"), "build-exe", "-fno-entry", "-rdynamic", *flags, "--dep", "wasdon",
         "-Mroot=main.zig", *flags, "-Mwasdon=bindings/root.zig", "-femit-bin=" + str(out / "program.wasm")], cwd=project)
    return project_inputs(project, out)


if __name__ == "__main__":
    main(declaration, generate, compile_project)
