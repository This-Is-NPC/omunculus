from .models import Item


class Inventory:
    def __init__(self):
        self.items = {}

    def add(self, sku, name, price_cents, quantity):
        item = self.items.get(sku)
        if item:
            item.quantity = quantity
        else:
            self.items[sku] = Item(sku, name, price_cents, quantity)

    def remove(self, sku, quantity):
        item = self.items[sku]
        if quantity > item.quantity:
            raise ValueError(f"only {item.quantity} of {sku} in stock")
        item.quantity -= quantity

    def total_cents(self):
        return sum(item.price_cents for item in self.items.values())
