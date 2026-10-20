import unittest

from inventory.report import money, summary
from inventory.store import Inventory


class InventoryTest(unittest.TestCase):
    def setUp(self):
        self.inventory = Inventory()
        self.inventory.add("A1", "Bolt", 25, 10)
        self.inventory.add("B2", "Nut", 10, 4)

    def test_adding_a_known_sku_adds_to_its_quantity(self):
        self.inventory.add("A1", "Bolt", 25, 5)
        self.assertEqual(self.inventory.items["A1"].quantity, 15)

    def test_removing_drops_an_item_out_of_stock(self):
        self.inventory.remove("B2", 4)
        self.assertNotIn("B2", self.inventory.items)

    def test_removing_more_than_in_stock_fails(self):
        with self.assertRaises(ValueError):
            self.inventory.remove("B2", 5)

    def test_total_is_price_times_quantity(self):
        self.assertEqual(self.inventory.total_cents(), 25 * 10 + 10 * 4)

    def test_money_has_two_decimals(self):
        self.assertEqual(money(290), "$2.90")
        self.assertEqual(money(5), "$0.05")

    def test_summary_lists_items_and_total(self):
        self.assertEqual(summary(self.inventory), "A1 Bolt x10\nB2 Nut x4\ntotal $2.90")


if __name__ == "__main__":
    unittest.main()
