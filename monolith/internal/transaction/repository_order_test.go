package transaction

import "testing"

func TestOrderedItemsForAllocation(t *testing.T) {
	input := []CreateItemRequest{
		{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2003", Amount: 1},
		{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001", Amount: 1},
		{ItemID: "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2002", Amount: 1},
	}

	ordered := orderedItemsForAllocation(input)
	if ordered[0].ItemID != "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001" ||
		ordered[1].ItemID != "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2002" ||
		ordered[2].ItemID != "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2003" {
		t.Fatalf("ordered items = %+v", ordered)
	}

	// Ensure input order is untouched.
	if input[0].ItemID != "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2003" {
		t.Fatalf("input mutated: %+v", input)
	}
}
