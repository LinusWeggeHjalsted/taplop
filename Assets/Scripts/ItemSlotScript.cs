using UnityEngine;
using UnityEngine.EventSystems;

public class ItemSlotScript : MonoBehaviour, IDropHandler
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public Transform playerGear;
    public Transform playerInventory;
    public GameObject skillsPanel;
    public SkillsPanelScript skillsPanelScript;
    public string itemType = "";
    public int inventoryPosition;

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        playerGear = player.transform.Find("Gear");
        playerInventory = player.transform.Find("Inventory");
        skillsPanel = GameObject.Find("Skills Panel");
        skillsPanelScript = skillsPanel.GetComponent<SkillsPanelScript>();
    }

    public void SwapWithOtherSlot(GameObject otherItemSlot, GameObject otherItem)
    {
        ItemSlotScript otherItemSlotScript = otherItemSlot.GetComponent<ItemSlotScript>();
        InventoryItemScript otherItemScript = otherItem.GetComponent<InventoryItemScript>();
        GameObject ownItem = this.transform.GetChild(0).gameObject;
        InventoryItemScript ownItemScript = ownItem.GetComponent<InventoryItemScript>();
        bool otherItemMatches = (itemType == otherItemScript.itemType || itemType == "");
        bool ownItemMatches = (otherItemSlotScript.itemType == ownItemScript.itemType || otherItemSlotScript.itemType == "");
        if (otherItemMatches && ownItemMatches)
        {
            otherItem.transform.parent = this.transform;
            otherItemScript.currentParent = this.transform;
            otherItem.transform.localPosition = new Vector3(0, 0, 0);
            ownItem.transform.parent = otherItemSlot.transform;
            ownItemScript.currentParent = otherItemSlot.transform;
            ownItem.transform.localPosition = new Vector3(0, 0, 0);

            Transform playerInventory = playerScript.inventory;

            GameObject actualOwnItem = ownItemScript.item;
            ItemScript actualOwnItemScript = actualOwnItem.GetComponent<ItemScript>();
            GameObject actualOtherItem = otherItemScript.item;
            ItemScript actualOtherItemScript = actualOtherItem.GetComponent<ItemScript>();

            // find where own item goes
            if (otherItemSlotScript.itemType != "")
            {

                switch (otherItemSlotScript.itemType)
                {
                    case "Weapon":
                        Transform targetHand;
                        if (otherItemSlot.transform.parent.name == "Main Hand")
                        {
                            targetHand = playerScript.mainHand;
                        }
                        else
                        {
                            targetHand = playerScript.offHand;
                        }
                        actualOwnItem.transform.parent = targetHand;
                        break;
                    case "Coat":
                        actualOwnItem.transform.parent = playerScript.body;
                        break;
                    case "Gloves":
                        actualOwnItem.transform.parent = playerScript.hands;
                        break;
                    case "Boots":
                        actualOwnItem.transform.parent = playerScript.feet;
                        break;
                }
            }
            else
            {
                actualOwnItem.transform.parent = playerInventory;
            }

            // find where other item goes
            if (itemType != "")
            {
                switch (itemType)
                {
                    case "Weapon":
                        Transform targetHand;
                        if (this.transform.parent.name == "Main Hand")
                        {
                            targetHand = playerScript.mainHand;
                        }
                        else
                        {
                            targetHand = playerScript.offHand;
                        }
                        actualOtherItem.transform.parent = targetHand;
                        break;
                    case "Coat":
                        actualOtherItem.transform.parent = playerScript.body;
                        break;
                    case "Gloves":
                        actualOtherItem.transform.parent = playerScript.hands;
                        break;
                    case "Boots":
                        actualOtherItem.transform.parent = playerScript.feet;
                        break;
                }
            }
            else
            {
                // this slot is inventory, so actualOtherItem should go to inventory
                actualOtherItem.transform.parent = playerInventory;
            }
            
            // swap inventoryPositions
            int ownPosition = actualOwnItemScript.inventoryPosition;
            int otherPosition = actualOtherItemScript.inventoryPosition;
            actualOwnItemScript.inventoryPosition = otherPosition;
            actualOtherItemScript.inventoryPosition = ownPosition;
            skillsPanelScript.UpdateButtons();
        }
    }

    public void OnDrop(PointerEventData eventData)
    {
        GameObject droppedItem = eventData.pointerDrag;
        InventoryItemScript itemScript = droppedItem.GetComponent<InventoryItemScript>();
        GameObject actualItem = itemScript.item;
        ItemScript actualItemScript = actualItem.GetComponent<ItemScript>();
        if (this.transform.childCount > 0)
        {
            SwapWithOtherSlot(itemScript.currentParent.gameObject, droppedItem);
        }
        else
        {
            if (itemType != "")
            {
                if (itemScript.itemType == itemType)
                {
                    itemScript.currentParent = this.transform;
                    switch (itemType)
                    {
                        case "Weapon":
                            Transform targetHand;
                            if (this.transform.parent.name == "Main Hand")
                            {
                                targetHand = playerScript.mainHand;
                            }
                            else
                            {
                                targetHand = playerScript.offHand;
                            }
                            actualItem.transform.parent = targetHand;
                            break;
                        case "Coat":
                            actualItem.transform.parent = playerScript.body;
                            break;
                        case "Gloves":
                            actualItem.transform.parent = playerScript.hands;
                            break;
                        case "Boots":
                            actualItem.transform.parent = playerScript.feet;
                            break;
                    }
                    skillsPanelScript.UpdateButtons();
                }
            }
            else
            {
                Transform originalItemSlot = itemScript.currentParent;
                ItemSlotScript originalItemSlotScript = originalItemSlot.GetComponent<ItemSlotScript>();
                if (originalItemSlotScript.itemType != "")
                {
                    actualItem.transform.parent = playerScript.inventory;
                    skillsPanelScript.UpdateButtons();
                }
                itemScript.currentParent = this.transform;
            }
            actualItemScript.inventoryPosition = this.inventoryPosition;
        }
    }
}
