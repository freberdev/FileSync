# Interop results

- Date: 2026-11-13 12:24:38 +0100
- Local rsync: openrsync: protocol version 29
- Remote rsync: rsync  version 3.2.7  protocol version 31
- Server: user@192.168.1.10

## Checks

- A: PASS 
- B: PASS 
- C: PASS 
- D: PASS 
- E: PASS 

partial-dir: ok

## F: unreachable host (filsynk@192.0.2.1)

Exit code: 255

```
ssh: connect to host 192.0.2.1 port 22: Operation timed out
rsync(1525): error: unexpected end of file
```

## G: rejected key (throwaway key against user@192.168.1.10)

Exit code: 255

```
user@192.168.1.10: Permission denied (publickey,password).
rsync(1528): error: unexpected end of file
```
