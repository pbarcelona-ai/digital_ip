# py_core test program (pyc.py --core 1): loops, shifts, compares, calls and recursion, globals,
# mem32 stores of every result (RAM at OUT), an interrupt handler counting entries, wait_irq().
OUT = 0x100
k = 0
n_irq = 0


def put(v):
    global k
    mem32[OUT + (k << 2)] = v & 0xFFFFFFFF
    k = k + 1


def tri(n):
    if n == 0:
        return 0
    return n + tri(n - 1)


def on_irq():
    global n_irq
    n_irq = n_irq + 1
    mem32[0x80] = n_irq


irq_handler(on_irq)
irq_enable()
a = -100000
while a < 100000:
    put(a + 12345)
    put(a - 777)
    put((a << 3) ^ 0x5A5A)
    put(a >> 2)
    if a < 0:
        put(1)
    else:
        put(2)
    a = a + 23456
put(tri(12))
irq_disable()
wait_irq()
irq_enable()
put(n_irq)
halt(k)
