import sets, times, osproc
import nimx.naketools

beforeBuild = proc(b: Builder) =
    b.mainFile = "rod_video"
    #b.additionalCompilerFlags.add("-g")
    if b.platform == "emscripten":
        for f in ["out.webm"]:
            b.emscriptenPreloadFiles.add(b.originalResourcePath & "/" & f & "@/res/" & f)
