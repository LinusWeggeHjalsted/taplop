using UnityEngine;
using UnityEngine.UI;

public class InventoryMenuScript : MonoBehaviour
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public Transform playerInventory;
    public GameObject itemSlotPrefab;
    public GameObject inventoryItemPrefab;

    public void RefreshUI()
    {
        // clear all existing item slots
        for (int i = this.transform.childCount - 1; i >= 0; i--)
        {
            Destroy(this.transform.GetChild(i).gameObject);
        }

        // rebuild inventory grid
        GameObject[] playerItems = playerScript.inventoryItems;
        for (int i = 0; i < playerScript.inventorySize; i++)
        {
            GameObject itemSlot = Instantiate(itemSlotPrefab, this.transform);
            ItemSlotScript itemSlotScript = itemSlot.GetComponent<ItemSlotScript>();
            itemSlotScript.inventoryPosition = i + 1;
            // look for item in this slot
            GameObject item = null;
            for (int j = 0; j < playerItems.Length; j++)
            {
                GameObject playerItem = playerItems[j];
                if (playerItem != null)
                {
                    ItemScript playerItemScript = playerItem.GetComponent<ItemScript>();
                    if (playerItemScript.inventoryPosition == i + 1)
                    {
                        item = playerItem;
                    }
                }
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
        itemSlotPrefab = Resources.Load<GameObject>("Prefabs/UI/Item Slot");
        inventoryItemPrefab = Resources.Load<GameObject>("Prefabs/UI/Inventory Item");
        RefreshUI();
    }
}
