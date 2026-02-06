using UnityEngine;
using UnityEngine.UI;
using TMPro;

public class InventoryMenuScript : MonoBehaviour
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public Transform playerInventory;
    public Transform inventorySlots;
    public GameObject itemSlotPrefab;
    public GameObject inventoryItemPrefab;
    public TextMeshProUGUI woodSalvageText;
    public TextMeshProUGUI metalSalvageText;
    public TextMeshProUGUI leatherSalvageText;
    public TextMeshProUGUI clothSalvageText;
    public TextMeshProUGUI knowledgeSalvageText;

    public void RefreshUI()
    {
        // clear all existing item slots
        for (int i = inventorySlots.childCount - 1; i >= 0; i--)
        {
            Destroy(inventorySlots.GetChild(i).gameObject);
        }

        // rebuild inventory grid
        GameObject[] playerItems = playerScript.inventoryItems;
        for (int i = 0; i < playerScript.inventorySize; i++)
        {
            GameObject itemSlot = Instantiate(itemSlotPrefab, inventorySlots);
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

        // update salvage text fields
        PlayerDataScript playerData = PlayerDataScript.Instance;
        if (playerData != null)
        {
            woodSalvageText.text = playerData.collectedSalvage.wood.ToString();
            metalSalvageText.text = playerData.collectedSalvage.metal.ToString();
            leatherSalvageText.text = playerData.collectedSalvage.leather.ToString();
            clothSalvageText.text = playerData.collectedSalvage.cloth.ToString();
            knowledgeSalvageText.text = playerData.collectedSalvage.knowledge.ToString();
        }
    }

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        playerInventory = player.transform.Find("Inventory");
        Transform horizontalLayout = this.transform.Find("Horizontal Layout");
        inventorySlots = horizontalLayout.Find("Inventory Slots");
        Transform inventorySidebar = horizontalLayout.Find("Inventory Sidebar");
        woodSalvageText = inventorySidebar.Find("Wood Salvage/Wood Salvage Text").GetComponent<TextMeshProUGUI>();
        metalSalvageText = inventorySidebar.Find("Metal Salvage/Metal Salvage Text").GetComponent<TextMeshProUGUI>();
        leatherSalvageText = inventorySidebar.Find("Leather Salvage/Leather Salvage Text").GetComponent<TextMeshProUGUI>();
        clothSalvageText = inventorySidebar.Find("Cloth Salvage/Cloth Salvage Text").GetComponent<TextMeshProUGUI>();
        knowledgeSalvageText = inventorySidebar.Find("Knowledge Salvage/Knowledge Salvage Text").GetComponent<TextMeshProUGUI>();
        itemSlotPrefab = Resources.Load<GameObject>("Prefabs/UI/Item Slot");
        inventoryItemPrefab = Resources.Load<GameObject>("Prefabs/UI/Inventory Item");
        RefreshUI();
    }
}
