using UnityEngine;
using UnityEngine.EventSystems;

public class ItemSlotScript : MonoBehaviour, IDropHandler
{
    public GameObject player;
    public EntityScript playerScript;
    public Transform playerGear;
    public Transform playerInventory;
    public GameObject skillsPanel;
    public SkillsPanelScript skillsPanelScript;
    public string itemType = "";

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<EntityScript>();
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

            // Get references to actual items before any modifications
            GameObject actualOwnItem = ownItemScript.item;
            GameObject actualOtherItem = otherItemScript.item;

            // Handle equipping items from otherItemSlot to this slot
            if (otherItemSlotScript.itemType != "")
            {
                switch (otherItemSlotScript.itemType)
                {
                    case "Weapon":
                        Transform targetHand = (otherItemSlot.transform.parent.name == "Main Hand")
                            ? playerScript.mainHand
                            : playerScript.offHand;
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
                // otherItemSlot is inventory, so actualOwnItem should go to inventory
                actualOwnItem.transform.parent = playerInventory;
            }

            // Handle equipping items from this slot to otherItemSlot
            if (itemType != "")
            {
                switch (itemType)
                {
                    case "Weapon":
                        Transform targetHand = (this.transform.parent.name == "Main Hand")
                            ? playerScript.mainHand
                            : playerScript.offHand;
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

            skillsPanelScript.UpdateButtons();
        }
    }

    public void OnDrop(PointerEventData eventData)
    {
        GameObject droppedItem = eventData.pointerDrag;
        InventoryItemScript itemScript = droppedItem.GetComponent<InventoryItemScript>();
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
                    GameObject actualItem = itemScript.item;
                    ItemScript actualItemScript = actualItem.GetComponent<ItemScript>();
                    switch (itemType)
                    {
                        case "Weapon":
                            Transform targetHand = (this.transform.parent.name == "Main Hand")
                                ? playerScript.mainHand
                                : playerScript.offHand;
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
                    GameObject actualItem = itemScript.item;
                    actualItem.transform.parent = playerScript.inventory;
                    skillsPanelScript.UpdateButtons();
                }
                itemScript.currentParent = this.transform;
            }
        }
    }
}
