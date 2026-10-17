// Shared by the organiser (advertises) and the student (scans).
//
// Advertisement layout (fits easily in the 31-byte legacy BLE limit):
//   flags (3) + service UUID 16-bit (4) + manufacturer data (2 + 2 + 8) = 19 bytes
//   manufacturer payload = [ sessionId : uint32 big-endian | token : 4 bytes ]
const kServiceUuid = '0000A11C-0000-1000-8000-00805F9B34FB'; // compacts to 16-bit A11C on air
const kServiceShort = 'A11C';                                 // same UUID, short form for scan filters
const kCompanyId = 0xFFFF;                                    // reserved "testing" manufacturer id
