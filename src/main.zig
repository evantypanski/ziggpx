const std = @import("std");
const Xml = @import("Xml");
const testing = std.testing;

const Gpx = @This();

xml: Xml,

const GpxError = error{
    NoTrkpt,
    NoTime,
    InvalidDatetime,
    InvalidTrkpt,
    SecondTimeBeforeFirst,
};

const DateTime = struct {
    const Self = @This();

    // Format: YYYY-MM-DDTHH:MM:SSZ
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,

    pub fn fromString(bytes: []const u8) !Self {
        // Allowing lack of Z at the end, I don't know if these are consistent
        if (bytes.len != 19 and bytes.len != 20) {
            return error.InvalidDatetime;
        }
        return .{
            .year = try std.fmt.parseUnsigned(i32, bytes[0..4], 10),
            .month = try std.fmt.parseUnsigned(i32, bytes[5..7], 10),
            .day = try std.fmt.parseUnsigned(i32, bytes[8..10], 10),
            .hour = try std.fmt.parseUnsigned(i32, bytes[11..13], 10),
            .minute = try std.fmt.parseUnsigned(i32, bytes[14..16], 10),
            .second = try std.fmt.parseUnsigned(i32, bytes[17..19], 10),
        };
    }

    // Time between in seconds
    pub fn timeBetween(self: Self, other: Self) !u64 {
        const secondsPerMinute: u32 = 60;
        const secondsPerHour: u32 = secondsPerMinute * 60;
        const secondsPerDay: u32 = secondsPerHour * 24;
        var difference: i64 = 0;

        // Calculate the number of seconds between the years
        difference += (other.year - self.year) * secondsPerDay * 365;

        // Add leap year days for the range of years
        difference += (@divFloor((other.year + 3), 4) - @divFloor((self.year + 3), 4)) * secondsPerDay;

        // Calculate the number of seconds between the months
        difference += (other.month - self.month) * secondsPerDay * try daysInMonth(@intCast(u32, self.year), @intCast(u32, self.month));

        // Calculate the number of seconds between the days
        difference += (other.day - self.day) * secondsPerDay;

        // Calculate the number of seconds between the hours
        difference += (other.hour - self.hour) * secondsPerHour;

        // Calculate the number of seconds between the minutes
        difference += (other.minute - self.minute) * secondsPerMinute;

        // Calculate the number of seconds between the seconds
        difference += other.second - self.second;

        return std.math.absCast(difference);
    }

    fn daysInMonth(year: u32, month: u32) !i32 {
        if (month > 12) {
            return error.InvalidDatetime;
        }
        const daysPerMonth = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        if (month == 2 and isLeapYear(year)) {
            return 29;
        }

        return daysPerMonth[month - 1];
    }

    fn isLeapYear(year: u32) bool {
        return (year % 4 == 0) and (year % 100 != 0 or year % 400 == 0);
    }
};

// Earth's radius mean
const R_MILES = 3959;
const R_KM = 6371;

const TrackPoint = struct {
    const Self = @This();

    lat: f32,
    lon: f32,
    // Whether the latitude and longitude are in degrees or radians
    unit: enum { DEGREES, RADIANS },

    datetime: DateTime,

    pub fn distanceMiles(self: Self, other: Self) f32 {
        return haversine(self, other, R_MILES);
    }

    pub fn distanceKm(self: Self, other: Self) f32 {
        return haversine(self, other, R_KM);
    }

    fn haversine(self: Self, other: Self, comptime radius: f32) f32 {
        var lat1: f32 = undefined;
        var lon1: f32 = undefined;
        var lat2: f32 = undefined;
        var lon2: f32 = undefined;

        const math = std.math;
        switch (self.unit) {
            .DEGREES => {
                lat1 = math.degreesToRadians(f32, self.lat);
                lon1 = math.degreesToRadians(f32, self.lon);
            },
            .RADIANS => {
                lat1 = self.lat;
                lon1 = self.lon;
            },
        }
        switch (other.unit) {
            .DEGREES => {
                lat2 = math.degreesToRadians(f32, other.lat);
                lon2 = math.degreesToRadians(f32, other.lon);
            },
            .RADIANS => {
                lat2 = other.lat;
                lon2 = other.lon;
            },
        }

        return 2 * radius * math.asin(math.sqrt(math.sin(((lat2 - lat1) / 2) * (lat2 - lat1) / 2) + math.cos(lat1) * math.cos(lat2) * math.sin(((lon2 - lon1) / 2) * ((lon2 - lon1) / 2))));
    }
};

// A split contains the distance travelled and time taken to travel that
// distance in seconds.
const Split = struct {
    const Self = @This();

    distance: f32,
    distance_unit: enum { MILES, KM },
    time: u64,

    // Calculates average number of seconds per split_distance in distance_unit
    pub fn averagePace(self: Self, split_distance: f32) u64 {
        const num_split_distances = self.distance / split_distance;
        return @floatToInt(u64, @intToFloat(f32, self.time) / num_split_distances);
    }
};

// Gets the next trackpoint from an XML file, or null if we're at the end.
// Returns an error if the trackpoint isn't formatted as we expect.
fn nextTrackpoint(xml: *Xml) !?TrackPoint {
    if (!skipUntil(xml, .tag_open, "trkpt")) {
        return null;
    }
    if (xml.next().tag != .attr_key) {
        return error.InvalidTrkpt;
    }
    // This token will be reused
    var tok = xml.next();
    if (tok.tag != .attr_value) {
        return error.InvalidTrkpt;
    }
    const lat: f32 = try std.fmt.parseFloat(f32, tok.bytes[1 .. tok.bytes.len - 1]);

    if (xml.next().tag != .attr_key) {
        return error.InvalidTrkpt;
    }
    tok = xml.next();
    if (tok.tag != .attr_value) {
        return error.InvalidTrkpt;
    }
    const lon: f32 = try std.fmt.parseFloat(f32, tok.bytes[1 .. tok.bytes.len - 1]);

    // May make this optional? Also at this point need to check if it's
    // still in the trkpt etc.
    if (!skipUntil(xml, .tag_open, "time")) {
        return error.InvalidTrkpt;
    }
    tok = xml.next();
    if (tok.tag != .content) {
        return error.InvalidTrkpt;
    }
    var datetime = try DateTime.fromString(tok.bytes);

    return TrackPoint{ .lat = lat, .lon = lon, .unit = .DEGREES, .datetime = datetime };
}

// Creates a split for the whole GPX file
fn calculateTotalSplit(gpx: *Gpx) !Split {
    var trkpt1 = try nextTrackpoint(&gpx.xml) orelse return error.NoTrkpt;
    var trkpt2: TrackPoint = undefined;

    var total_distance: f32 = 0;
    var total_time: u64 = 0;

    while (try nextTrackpoint(&gpx.xml)) |trkpt| {
        trkpt2 = trkpt1;
        trkpt1 = trkpt;

        total_distance += trkpt1.distanceMiles(trkpt2);
        total_time += try trkpt1.datetime.timeBetween(trkpt2.datetime);
    }

    return Split{ .distance = total_distance, .distance_unit = .MILES, .time = total_time };
}

fn skipUntil(xml: *Xml, tag: Xml.Token.Tag, name: []const u8) bool {
    while (true) {
        const tok = xml.next();
        if (tok.tag == .invalid or tok.tag == .eof) {
            return false;
        }

        if (tok.tag == tag and std.mem.eql(u8, tok.bytes, name)) {
            return true;
        }
    }
}

test "test 5k" {
    const file = try std.fs.cwd().openFile("test/Running_of_the_leprechauns_5k.gpx", .{ .mode = .read_only });
    const bytes = try file.readToEndAlloc(std.testing.allocator, 1000000000);
    var gpx: Gpx = .{ .xml = .{ .bytes = bytes } };
    const split = try gpx.calculateTotalSplit();
    try std.testing.expectEqual(split.distance_unit, .MILES);
    try std.testing.expectApproxEqRel(split.distance, 3.1, 0.1);
    // No expect approx eq for ints, but we want some tolerance for average pace
    const avg_pace = split.averagePace(1);
    const expected_avg_pace = 396;
    try std.testing.expect(std.math.absCast(avg_pace - expected_avg_pace) <= 5);
    std.testing.allocator.free(bytes);
}

test "test marathon" {
    const file = try std.fs.cwd().openFile("test/Atlanta_marathon_.gpx", .{ .mode = .read_only });
    const bytes = try file.readToEndAlloc(std.testing.allocator, 1000000000);
    var gpx: Gpx = .{ .xml = .{ .bytes = bytes } };
    const split = try gpx.calculateTotalSplit();
    try std.testing.expectEqual(split.distance_unit, .MILES);
    try std.testing.expectApproxEqRel(split.distance, 26.2, 0.1);
    // No expect approx eq for ints, but we want some tolerance for average pace
    const avg_pace = split.averagePace(1);
    const expected_avg_pace = 528;
    try std.testing.expect(std.math.absCast(avg_pace - expected_avg_pace) <= 5);
    std.testing.allocator.free(bytes);
}
