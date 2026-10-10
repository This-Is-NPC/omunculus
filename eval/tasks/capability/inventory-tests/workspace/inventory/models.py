from dataclasses import dataclass


@dataclass
class Item:
    sku: str
    name: str
    price_cents: int
    quantity: int = 0
