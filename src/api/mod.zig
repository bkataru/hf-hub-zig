//! API operations for HuggingFace Hub
//!
//! This module provides access to all HuggingFace Hub API operations:
//! - Models: Search, list, and get model information
//! - Files: File metadata and download URL generation
//! - User: Authentication and user information

pub const files = @import("files.zig");
pub const FilesApi = files.FilesApi;
pub const LfsPointer = files.LfsPointer;
pub const models = @import("models.zig");
pub const ModelsApi = models.ModelsApi;
pub const freeFileInfoSlice = models.freeFileInfoSlice;
pub const freeSearchResult = models.freeSearchResult;
pub const user = @import("user.zig");
pub const UserApi = user.UserApi;
pub const TokenInfo = user.TokenInfo;

// Re-export main types for convenience
// Re-export utility types
// Re-export helper functions
// Tests
test {
    @import("std").testing.refAllDecls(@This());
}
