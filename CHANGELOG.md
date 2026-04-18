# Changelog

All notable changes to this project will be documented in this file.

## [0.0.1.0] - 2026-04-18

### Fixed

- Git cleanup now detects tracked files that match gitignore patterns and untracks them (`git rm --cached`), keeping files on disk but removing them from version control (e.g., `wp-content/wpvivid_image_optimization/`)
- Obsolete tracked files like `.maintenance-flags` are now deleted during cleanup, since per-site preferences are managed at root level by runcloud-go
- Scan mode reports tracked files that shouldn't be tracked (obsolete + artifact counts)
