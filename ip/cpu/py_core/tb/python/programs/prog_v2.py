# py_core test program (pyc.py --core 2): * // % on every sign combination (Python floor semantics),
# large operands, recursion, globals, mem32 stores of every result, an interrupt handler, wait_irq().
OUT = 0x100
k = 0
n_irq = 0


def put(v):
    global k
    mem32[OUT + 4 * k] = v & 0xFFFFFFFF
    k = k + 1


def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


def on_irq():
    global n_irq
    n_irq = n_irq + 1
    mem32[0x80] = n_irq


irq_handler(on_irq)
irq_enable()
a = -1000
while a < 1001:
    b = -9
    while b < 10:
        if b != 0:
            put(a // b)
            put(a % b)
        put(a * b)
        b = b + 4
    a = a + 287
big = 0x7FFFFFFF
put(big * 2)
put(big // 3)
put((0 - big) % 1000)
put((0 - big) // 7)
m = 65535
put(m * m)
put(fib(11))
irq_disable()
wait_irq()
irq_enable()
put(n_irq)
halt(k)
