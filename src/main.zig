const r4os = @import("r4os");

const operator_offsets = [_]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
    0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
};

comptime {
    asm (r4os.r4dev.protocolEntriesAsm("opl3_init", "opl3_shutdown", "opl3_query", "opl3_dispatch"));
}

export fn opl3_init(api: *const r4os.r4dev.ProtocolApi) callconv(.c) i32 {
    var ctx = r4os.r4dev.ProtocolContext.init(api);
    ctx.logInfo("OPL3.R4P init");
    _ = ctx.registerRole("audio.opl3", .audio, 0);
    _ = ctx.setStatus(.active, "OPL3 protocol R4P active");
    return 0;
}

export fn opl3_shutdown() callconv(.c) i32 {
    return 0;
}

export fn opl3_query(out: *r4os.abi.ProtocolStatus) callconv(.c) i32 {
    out.* = .{
        .state = @intFromEnum(r4os.abi.ProtocolState.active),
        .flags = 0,
        .last_error = 0,
        .reserved = 0,
        .note = note("OPL3 protocol R4P ready"),
    };
    return 0;
}

export fn opl3_dispatch(op: u32, in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) callconv(.c) i32 {
    _ = out_buffer;
    const request = requestFromBuffer(in_buffer) orelse return r4os.abi.audio_opl3_result_bad_event;
    switch (op) {
        r4os.abi.audio_opl3_op_reset => reset(request),
        r4os.abi.audio_opl3_op_write_register => classifyRegister(request),
        r4os.abi.audio_opl3_op_midi_event => classifyMidi(request),
        r4os.abi.audio_opl3_op_self_test => selfTest(request),
        else => return r4os.abi.audio_opl3_result_unsupported,
    }
    return request.result;
}

fn reset(op: *r4os.abi.AudioOpl3Op) void {
    op.write_kind = r4os.abi.audio_opl3_write_other;
    op.action = r4os.abi.audio_opl3_action_ignore;
    op.result = r4os.abi.audio_opl3_result_ok;
}

fn classifyRegister(op: *r4os.abi.AudioOpl3Op) void {
    if (op.bank > 1) {
        op.result = r4os.abi.audio_opl3_result_bad_register;
        return;
    }
    const reg = op.register;
    op.write_kind = r4os.abi.audio_opl3_write_other;
    if ((op.bank == 1 and (reg == 0x04 or reg == 0x05)) or (op.bank == 0 and (reg == 0x01 or reg == 0xBD))) {
        op.write_kind = r4os.abi.audio_opl3_write_global;
    } else if (isOperatorRegister(reg)) {
        op.write_kind = r4os.abi.audio_opl3_write_operator;
    } else if (isChannelRegister(reg)) {
        op.write_kind = r4os.abi.audio_opl3_write_channel;
    }
    op.result = r4os.abi.audio_opl3_result_ok;
}

fn classifyMidi(op: *r4os.abi.AudioOpl3Op) void {
    if (op.channel > 15) {
        op.result = r4os.abi.audio_opl3_result_bad_event;
        return;
    }
    const status = op.status & 0xF0;
    op.normalized_status = status;
    op.action = r4os.abi.audio_opl3_action_ignore;
    switch (status) {
        0x80 => {
            op.action = r4os.abi.audio_opl3_action_note_off;
            op.note = op.data1 & 0x7F;
        },
        0x90 => {
            op.note = op.data1 & 0x7F;
            op.velocity = op.data2 & 0x7F;
            if (op.velocity == 0) {
                op.action = r4os.abi.audio_opl3_action_note_off;
                op.normalized_status = 0x80;
            } else {
                op.action = r4os.abi.audio_opl3_action_note_on;
            }
        },
        0xB0 => {
            op.controller = op.data1 & 0x7F;
            op.velocity = op.data2 & 0x7F;
            if (op.controller == 120 or op.controller == 123) {
                op.action = r4os.abi.audio_opl3_action_all_notes_off;
            } else if (op.controller == 7 or op.controller == 10 or op.controller == 11 or op.controller == 121) {
                op.action = r4os.abi.audio_opl3_action_control;
            }
        },
        0xC0 => {
            op.action = r4os.abi.audio_opl3_action_program;
            op.program = op.data1 & 0x7F;
        },
        else => {},
    }
    op.result = r4os.abi.audio_opl3_result_ok;
}

fn selfTest(op: *r4os.abi.AudioOpl3Op) void {
    var probe: r4os.abi.AudioOpl3Op = .{ .bank = 1, .register = 0x05, .value = 0x01 };
    classifyRegister(&probe);
    if (probe.result != r4os.abi.audio_opl3_result_ok or probe.write_kind != r4os.abi.audio_opl3_write_global) {
        op.result = r4os.abi.audio_opl3_result_bad_register;
        return;
    }
    probe = .{ .bank = 0, .register = 0x20, .value = 0x21 };
    classifyRegister(&probe);
    if (probe.write_kind != r4os.abi.audio_opl3_write_operator) {
        op.result = r4os.abi.audio_opl3_result_bad_register;
        return;
    }
    probe = .{ .channel = 0, .status = 0x90, .data1 = 60, .data2 = 96 };
    classifyMidi(&probe);
    if (probe.action != r4os.abi.audio_opl3_action_note_on or probe.note != 60 or probe.velocity != 96) {
        op.result = r4os.abi.audio_opl3_result_bad_event;
        return;
    }
    probe = .{ .channel = 0, .status = 0xB0, .data1 = 123, .data2 = 0 };
    classifyMidi(&probe);
    if (probe.action != r4os.abi.audio_opl3_action_all_notes_off) {
        op.result = r4os.abi.audio_opl3_result_bad_event;
        return;
    }
    op.result = r4os.abi.audio_opl3_result_ok;
}

fn isOperatorRegister(reg: u8) bool {
    const family = reg & 0xE0;
    if (family != 0x20 and family != 0x40 and family != 0x60 and family != 0x80 and family != 0xE0) return false;
    const offset = reg & 0x1F;
    for (operator_offsets) |candidate| {
        if (candidate == offset) return true;
    }
    return false;
}

fn isChannelRegister(reg: u8) bool {
    const lo = reg & 0x0F;
    if (lo > 8) return false;
    return (reg >= 0xA0 and reg <= 0xA8) or (reg >= 0xB0 and reg <= 0xB8) or (reg >= 0xC0 and reg <= 0xC8);
}

fn requestFromBuffer(buffer: *const r4os.abi.ProtocolBuffer) ?*r4os.abi.AudioOpl3Op {
    if (buffer.data == null) return null;
    if (buffer.len < @sizeOf(r4os.abi.AudioOpl3Op)) return null;
    return @ptrCast(@alignCast(buffer.data.?));
}

fn note(comptime text: []const u8) [64]u8 {
    var out: [64]u8 = .{0} ** 64;
    @memcpy(out[0..text.len], text);
    return out;
}
