using UnityEngine;
using UnityEngine.UI;

public class InventoryUIScript : MonoBehaviour
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public Transform playerInventory;
    public GameObject itemSlotPrefab;
    public GameObject inventoryItemPrefab;

    public void RefreshUI()
    {
        // Clear all existing item slots
        for (int i = this.transform.childCount - 1; i >= 0; i--)
        {
            Destroy(this.transform.GetChild(i).gameObject);
        }

        // Rebuild inventory grid
        for (int i = 0; i < 24; i++)
        {
            GameObject itemSlot = Instantiate(itemSlotPrefab, this.transform);
            GameObject item = null;
            if (i < playerInventory.childCount)
            {
                item = playerInventory.GetChild(i).gameObject;
            }
            if (item != null)
            {
                ItemScript itemScript = item.GetComponent<ItemScript>();
                Sprite itemSprite = itemScript.GetSprite();
                GameObject inventoryItem = Instantiate(inventoryItemPrefab, itemSlot.transform);
                InventoryItemScript inventoryItemScript = inventoryItem.GetComponent<InventoryItemScript>();
                inventoryItemScript.item = item;
                Image itemImage = inventoryItem.GetComponent<Image>();
                itemImage.sprite = itemSprite;
            }
        }
    }

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        playerInventory = player.transform.Find("Inventory");
        itemSlotPrefab = Resources.Load<GameObject>("Prefabs/Item Slot");
        inventoryItemPrefab = Resources.Load<GameObject>("Prefabs/Inventory Item");
        RefreshUI();
    }
}
