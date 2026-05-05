# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed
- **common/install.sh**: Removed references to non-existent `$MODPATH/system/` directory that caused installation failures
- **cpu_hog_killer.sh**: Fixed associative array clearing in `cleanup_measurements()` function using proper `unset` + `declare -A` pattern
- **customize.sh**: Removed undefined `set_permissions()` function that called non-existent `set_perm` command
- **service.sh**: Removed duplicate "Service script started." log message

### Changed
- **cpu_hog_killer.sh**: Refactored code for better maintainability:
  - Added clear section headers for organization
  - Broke down monolithic `monitor_and_analyze()` into smaller, focused functions
  - Removed commented-out debug code and unused variables
  - Improved variable scoping with consistent `local` usage
  - Enhanced function naming conventions and control flow clarity

### Documentation
- **README.md**: Fixed typos, grammar errors, and formatting inconsistencies:
  - Corrected "Magisk" capitalization
  - Fixed possessive "its" vs contraction "it's"
  - Added proper hyphenation for compound adjectives (CPU-intensive, non-CPU-intensive)
  - Improved punctuation and readability

## [1.0.0] - Initial Release

### Added
- CPU hog detection and automatic termination service
- Configurable CPU threshold monitoring
- Process history tracking for instability detection
- Notification system for killed processes
- Magisk module integration for system-level operation
- Customizable configuration via `config.sh`
- Installation and uninstallation scripts
- Comprehensive documentation

### Features
- Monitors top CPU-consuming processes every 5 seconds
- Maintains 6-cycle history for process stability analysis
- Automatically kills processes exceeding CPU threshold (default 80%)
- Detects and reports rapidly respawning unstable processes
- Logs all actions to Magisk log system
- Supports exclusion list for critical system processes
