# T7 - Release preparation for 0.0.3 beta

1. Add CHANGELOG.md (0.0.1 -> 0.0.3) from git history and docs/DEVELOPMENT.md.
2. Add README.zh-CN.md, a faithful Chinese version of README.md, and link the two.
3. Write docs/release-0.0.3.md: release notes in English and Chinese.
4. Make installer/build.sh cross-compile the Windows installer on Linux (GOOS=windows); verify it builds here and report the exe size. Do not commit the exe.
Push `cloud/t7-release`, PR into `dev-0.0.3`, summary in Chinese. Do not create a GitHub release.
