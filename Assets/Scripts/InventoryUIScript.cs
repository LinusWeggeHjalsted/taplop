using UnityEngine;
using UnityEngine.UI;

public class InventoryUIScript : MonoBehaviour
{
    public GameObject player;
    public EntityScript playerScript;
    public Transform playerInventory;
    public GameObject itemSlotPrefab;
    public GameObject inventoryItemPrefab;

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<EntityScript>();
        playerInventory = player.transform.Find("Inventory");
        itemSlotPrefab = Resources.Load<GameObject>("Prefabs/Item Slot");
        inventoryItemPrefab = Resources.Load<GameObject>("Prefabs/Inventory Item");
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
}
