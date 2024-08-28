const std = @import("std");
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;

const EPOCH_LENGTH = 600;
const VALIDATOR_COUNT = 1023;

const Ticket = struct {
    validator_index: u32,
    score: u64,

    fn cmp(_: void, a: Ticket, b: Ticket) bool {
        return a.score < b.score;
    }
};

fn cmpByTicket(_: void, a: Ticket, b: Ticket) bool {
    return a.score < b.score;
}

const Block = struct {
    parent_hash: [32]u8,
    slot: u32,
    author: u32,
};

const Safrole = struct {
    current_epoch: u32,
    current_slot: u32,
    validators: [VALIDATOR_COUNT]u32,
    sealing_keys: [EPOCH_LENGTH]u32,
    ticket_accumulator: ArrayList(Ticket),
    blocks: AutoHashMap(u32, Block),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Safrole {
        var self = Safrole{
            .current_epoch = 0,
            .current_slot = 0,
            .validators = undefined,
            .sealing_keys = undefined,
            .ticket_accumulator = ArrayList(Ticket).init(allocator),
            .blocks = AutoHashMap(u32, Block).init(allocator),
            .allocator = allocator,
        };

        // Initialize validators (in a real implementation, this would be more complex)
        for (&self.validators, 0..) |*validator, i| {
            validator.* = @intCast(i);
        }

        try self.generateSealingKeys();
        return self;
    }

    pub fn deinit(self: *Safrole) void {
        self.ticket_accumulator.deinit();
        self.blocks.deinit();
    }

    pub fn generateSealingKeys(self: *Safrole) !void {
        // In a real implementation, this would use Bandersnatch Ringvrf
        // Here, we'll just use a simple random selection
        var prng = std.Random.DefaultPrng.init(self.current_epoch);
        const random = prng.random();

        for (&self.sealing_keys) |*key| {
            key.* = self.validators[random.intRangeLessThan(u32, 0, VALIDATOR_COUNT)];
        }
    }

    pub fn submitTicket(self: *Safrole, validator_index: u32, score: u64) !void {
        const ticket = Ticket{ .validator_index = validator_index, .score = score };
        try self.ticket_accumulator.append(ticket);
    }

    pub fn processTickets(self: *Safrole) !void {
        std.mem.sort(Ticket, self.ticket_accumulator.items, {}, Ticket.cmp);
        if (self.ticket_accumulator.items.len > EPOCH_LENGTH) {
            self.ticket_accumulator.shrinkRetainingCapacity(EPOCH_LENGTH);
        }
    }

    pub fn createBlock(self: *Safrole, parent_hash: [32]u8) !void {
        const author = self.sealing_keys[self.current_slot % EPOCH_LENGTH];
        const block = Block{
            .parent_hash = parent_hash,
            .slot = self.current_slot,
            .author = author,
        };
        try self.blocks.put(self.current_slot, block);
        self.current_slot += 1;

        if (self.current_slot % EPOCH_LENGTH == 0) {
            self.current_epoch += 1;
            try self.generateSealingKeys();
            self.ticket_accumulator.clearRetainingCapacity();
        }
    }

    pub fn isValidAuthor(self: Safrole, slot: u32, author: u32) bool {
        return self.sealing_keys[slot % EPOCH_LENGTH] == author;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var safrole = try Safrole.init(allocator);
    defer safrole.deinit();

    // Simulate some ticket submissions
    try safrole.submitTicket(0, 100);
    try safrole.submitTicket(1, 200);
    try safrole.submitTicket(2, 150);

    try safrole.processTickets();

    // Create some blocks
    var parent_hash: [32]u8 = undefined;
    std.crypto.random.bytes(&parent_hash);

    for (0..10) |_| {
        try safrole.createBlock(parent_hash);
        std.crypto.random.bytes(&parent_hash);
    }

    // Check if a block author is valid
    const is_valid = safrole.isValidAuthor(5, safrole.sealing_keys[5]);
    std.debug.print("Is author valid for slot 5? {}\n", .{is_valid});
}
