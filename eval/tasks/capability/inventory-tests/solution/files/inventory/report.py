def money(cents):
    return f"${cents // 100}.{cents % 100:02d}"


def summary(inventory):
    lines = [f"{item.sku} {item.name} x{item.quantity}" for item in inventory.items.values()]
    return "\n".join(lines + [f"total {money(inventory.total_cents())}"])
