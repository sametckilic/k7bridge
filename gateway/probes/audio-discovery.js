"use strict";

// Read-only discovery probe. It records call-stack and AudioUnit metadata but never
// reads, modifies or writes an audio buffer.
const targets = ["AudioUnitRender", "AudioUnitSetProperty", "AudioOutputUnitStart", "AudioOutputUnitStop"];

for (const name of targets) {
  const address = Module.findGlobalExportByName(name);
  if (!address) { send({ kind: "missing", process: Process.name, symbol: name }); continue; }
  Interceptor.attach(address, {
    onEnter(args) {
      this.started = Date.now();
      const event = { kind: "call", process: Process.name, symbol: name, threadId: this.threadId };
      if (name === "AudioUnitRender") {
        event.bus = args[3].toUInt32(); event.frames = args[4].toUInt32();
      } else if (name === "AudioUnitSetProperty") {
        event.property = args[1].toUInt32(); event.scope = args[2].toUInt32(); event.element = args[3].toUInt32();
      }
      event.backtrace = Thread.backtrace(this.context, Backtracer.ACCURATE).slice(0, 12).map(DebugSymbol.fromAddress).map(String);
      send(event);
    },
    onLeave(retval) { send({ kind: "return", process: Process.name, symbol: name, status: retval.toInt32(), elapsedMs: Date.now() - this.started }); }
  });
}

