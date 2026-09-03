# RTCGit fixtures

The RTC-101 corpus is derived from the canonical `tests/git.test.ts` fixture:
rename/copy/delete/add/binary files, hostile newline/tab/HTML names, dirty
working trees, symlink roots, SHA-256 repositories, and the 1 MiB/8 MiB/2,000
file caps. Tests construct repositories under temporary directories so no
fixture writes occur in a reviewed repository.
