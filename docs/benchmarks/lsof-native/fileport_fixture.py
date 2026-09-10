"""A controlled counterexample: a TCP socket owned only by a Mach fileport.

No existing sockets are modified. The send right is released in finally.
"""
import ctypes
import json
import socket
import compare

def main():
    lib = ctypes.CDLL(None, use_errno=True)
    lib.fileport_makeport.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint)]
    lib.mach_port_deallocate.argtypes = [ctypes.c_uint, ctypes.c_uint]
    sock = socket.socket()
    sock.bind(('127.0.0.1', 0))
    sock.listen()
    port = sock.getsockname()[1]
    right = ctypes.c_uint()
    status = lib.fileport_makeport(sock.fileno(), ctypes.byref(right))
    sock.close()
    if status != 0:
        raise OSError(ctypes.get_errno(), 'fileport_makeport')
    try:
        lsof, _ = compare.lsof()
        native, _ = compare.native()
        result = dict(fixture='fileport-only TCP listener',
                      lsof_matches=sum(row[5] == port for row in lsof),
                      native_matches=sum(row[5] == port for row in native))
        (compare.ROOT / 'fileport-result.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(result))
    finally:
        lib.mach_port_deallocate(ctypes.c_uint.in_dll(lib, 'mach_task_self_'), right)

if __name__ == '__main__':
    main()
