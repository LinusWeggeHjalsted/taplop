using UnityEngine;
using UnityEngine.UI;
using TMPro;

public class InventoryMenuScript : MonoBehaviour
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public Transform playerInventory;
    public Transform selectionHighlight;
    public Transform inventorySlots;
    public GameObject itemSlotPrefab;
    public GameObject inventoryItemPrefab;
    public TextMeshProUGUI woodSalvageText;
    public TextMeshProUGUI metalSalvageText;
    public TextMeshProUGUI leatherSalvageText;
    public TextMeshProUGUI clothSalvageText;
    public TextMeshProUGUI knowledgeSalvageText;
    public bool isShiftDragging = false;
    public int _beginDragCornerIndex = 0;
    public int _endDragCornerIndex = 0;
    public int beginDragCornerIndex
    {
        get
        {
            return _beginDragCornerIndex;
        }
        set
        {
            _beginDragCornerIndex = value;
        }
    }
    public int endDragCornerIndex
    {
        get
        {
            return _endDragCornerIndex;
        }
        set
        {
            if (_endDragCornerIndex != value)
            {
                _endDragCornerIndex = value;
                UpdateSelectionHighlight();
            }
        }
    }

    public Vector3 ScreenCoordinatesFromIndex(int index)
    {
        // to-do - think about this, is it the right approach?
        // 1-indexed
        Transform itemSlot = inventorySlots.GetChild(index - 1);
        return itemSlot.position; // to-do - fix if not center of the item slot
    }

    public Vector2 GridCoordinatesFromIndex(int index)
    {
        // 1-indexed
        // converted to coordinates in 8x12 grid
        int x = (index - 1) % 8;
        int y = (index - 1) / 8;
        return new Vector2((float)x, (float)y);
    }

    public int IndexFromGridCoordinates(Vector2 gridCoordinates)
    {
        return ((int)gridCoordinates.y * 8) + ((int)gridCoordinates.x + 1);
    }

    public void UpdateSelectionHighlight()
    {
        if (beginDragCornerIndex == 0 || endDragCornerIndex == 0)
        {
            selectionHighlight.gameObject.SetActive(false);
            return;
        }
        Vector3 firstCornerCoordinates = ScreenCoordinatesFromIndex(beginDragCornerIndex);
        Vector3 lastCornerCoordinates = ScreenCoordinatesFromIndex(endDragCornerIndex);

        // calculate center position and size
        Vector3 centerPosition = (firstCornerCoordinates + lastCornerCoordinates) / 2f;
        float width = Mathf.Abs(lastCornerCoordinates.x - firstCornerCoordinates.x);
        float height = Mathf.Abs(lastCornerCoordinates.y - firstCornerCoordinates.y);

        // get the size of a single item slot to account for slot dimensions
        Transform firstItemSlot = inventorySlots.GetChild(beginDragCornerIndex - 1);
        RectTransform firstItemSlotRect = firstItemSlot.GetComponent<RectTransform>();
        float slotWidth = firstItemSlotRect.rect.width;
        float slotHeight = firstItemSlotRect.rect.height;

        // add one slot size to width and height to properly cover the area
        width += slotWidth;
        height += slotHeight;

        // position and resize the selection highlight
        RectTransform highlightRect = selectionHighlight.GetComponent<RectTransform>();
        highlightRect.position = centerPosition;
        highlightRect.sizeDelta = new Vector2(width, height);

        selectionHighlight.gameObject.SetActive(true);
    }

    public void SalvageSelection()
    {
        if (beginDragCornerIndex == 0 || endDragCornerIndex == 0)
        {
            return;
        }
        Vector2 firstCornerCoordinates = GridCoordinatesFromIndex(beginDragCornerIndex);
        Vector2 lastCornerCoordinates = GridCoordinatesFromIndex(endDragCornerIndex);
        float minX = Mathf.Min(firstCornerCoordinates.x, lastCornerCoordinates.x);
        float maxX = Mathf.Max(firstCornerCoordinates.x, lastCornerCoordinates.x);
        float minY = Mathf.Min(firstCornerCoordinates.y, lastCornerCoordinates.y);
        float maxY = Mathf.Max(firstCornerCoordinates.y, lastCornerCoordinates.y);

        // collect all items in the selection area
        GameObject[] playerItems = playerScript.inventoryItems;
        PlayerDataScript.Salvage totalSalvage = new PlayerDataScript.Salvage();
        int itemsSalvaged = 0;

        for (int i = playerItems.Length - 1; i >= 0; i--)
        {
            GameObject playerItem = playerItems[i];
            if (playerItem != null)
            {
                ItemScript itemScript = playerItem.GetComponent<ItemScript>();
                int itemPosition = itemScript.inventoryPosition;
                Vector2 itemGridCoords = GridCoordinatesFromIndex(itemPosition);

                // check if item is within selection bounds
                if (itemGridCoords.x >= minX && itemGridCoords.x <= maxX &&
                    itemGridCoords.y >= minY && itemGridCoords.y <= maxY)
                {
                    // add salvage value
                    PlayerDataScript.Salvage salvageValue = itemScript.SalvageValue();
                    totalSalvage += salvageValue;
                    itemsSalvaged++;
                    // destroy the item
                    DestroyImmediate(playerItem);
                }
            }
        }

        // play sound and add salvage if any items were salvaged
        if (itemsSalvaged > 0)
        {
            SoundControllerScript.Instance.PlaySalvageSound();
            PlayerDataScript.Instance.collectedSalvage += totalSalvage;
            RefreshUI();
        }
    }

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
        selectionHighlight = this.transform.Find("Selection Highlight");
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
