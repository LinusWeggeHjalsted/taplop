using UnityEngine;
using UnityEngine.UI;

public class GearUIScript : MonoBehaviour
{
    public GameObject player;
    public EntityScript playerScript;
    public GameObject inventoryItemPrefab;
    public Transform mainHandItemSlot;
    public Transform offHandItemSlot;
    public Transform bodyItemSlot;
    public Transform handsItemSlot;
    public Transform feetItemSlot;

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<EntityScript>();
        inventoryItemPrefab = Resources.Load<GameObject>("Prefabs/Inventory Item");
        Transform gearSlots = this.transform.Find("Gear Slots");
        Transform mainHand = gearSlots.Find("Main Hand");
        Transform offHand = gearSlots.Find("Off Hand");
        Transform body = gearSlots.Find("Body");
        Transform hands = gearSlots.Find("Hands");
        Transform feet = gearSlots.Find("Feet");
        mainHandItemSlot = mainHand.GetChild(0);
        offHandItemSlot = offHand.GetChild(0);
        bodyItemSlot = body.GetChild(0);
        handsItemSlot = hands.GetChild(0);
        feetItemSlot = feet.GetChild(0);

        ItemSlotScript mainHandItemSlotScript = mainHandItemSlot.GetComponent<ItemSlotScript>();
        mainHandItemSlotScript.itemType = "Weapon";

        ItemSlotScript offHandItemSlotScript = offHandItemSlot.GetComponent<ItemSlotScript>();
        offHandItemSlotScript.itemType = "Weapon";

        ItemSlotScript bodyItemSlotScript = bodyItemSlot.GetComponent<ItemSlotScript>();
        bodyItemSlotScript.itemType = "Coat";

        ItemSlotScript handsItemSlotScript = handsItemSlot.GetComponent<ItemSlotScript>();
        handsItemSlotScript.itemType = "Gloves";

        ItemSlotScript feetItemSlotScript = feetItemSlot.GetComponent<ItemSlotScript>();
        feetItemSlotScript.itemType = "Boots";

        GameObject mainHandWeapon = playerScript.mainHandWeapon;
        GameObject offHandWeapon = playerScript.offHandWeapon;
        GameObject coat = playerScript.coat;
        GameObject gloves = playerScript.gloves;
        GameObject boots = playerScript.boots;
        
        if (mainHandWeapon != null)
        {
            ItemScript mainHandWeaponScript = mainHandWeapon.GetComponent<ItemScript>();
            Sprite mainHandWeaponSprite = mainHandWeaponScript.GetSprite();
            GameObject mainHandItem = Instantiate(inventoryItemPrefab, mainHandItemSlot);
            InventoryItemScript mainHandItemScript = mainHandItem.GetComponent<InventoryItemScript>();
            mainHandItemScript.item = mainHandWeapon;
            Image mainHandItemImage = mainHandItem.GetComponent<Image>();
            mainHandItemImage.sprite = mainHandWeaponSprite;
        }
        if (offHandWeapon != null)
        {
            ItemScript offHandWeaponScript = offHandWeapon.GetComponent<ItemScript>();
            Sprite offHandWeaponSprite = offHandWeaponScript.GetSprite();
            GameObject offHandItem = Instantiate(inventoryItemPrefab, offHandItemSlot);
            InventoryItemScript offHandItemScript = offHandItem.GetComponent<InventoryItemScript>();
            offHandItemScript.item = offHandWeapon;
            Image offHandItemImage = offHandItem.GetComponent<Image>();
            offHandItemImage.sprite = offHandWeaponSprite;
        }
        if (coat != null)
        {
            ItemScript coatScript = coat.GetComponent<ItemScript>();
            Sprite coatSprite = coatScript.GetSprite();
            GameObject coatItem = Instantiate(inventoryItemPrefab, bodyItemSlot);
            InventoryItemScript coatItemScript = coatItem.GetComponent<InventoryItemScript>();
            coatItemScript.item = coat;
            Image coatItemImage = coatItem.GetComponent<Image>();
            coatItemImage.sprite = coatSprite;
        }
        if (gloves != null)
        {
            ItemScript glovesScript = gloves.GetComponent<ItemScript>();
            Sprite glovesSprite = glovesScript.GetSprite();
            GameObject glovesItem = Instantiate(inventoryItemPrefab, handsItemSlot);
            InventoryItemScript glovesItemScript = glovesItem.GetComponent<InventoryItemScript>();
            glovesItemScript.item = gloves;
            Image glovesItemImage = glovesItem.GetComponent<Image>();
            glovesItemImage.sprite = glovesSprite;
        }
        if (boots != null)
        {
            ItemScript bootsScript = boots.GetComponent<ItemScript>();
            Sprite bootsSprite = bootsScript.GetSprite();
            GameObject bootsItem = Instantiate(inventoryItemPrefab, feetItemSlot);
            InventoryItemScript bootsItemScript = bootsItem.GetComponent<InventoryItemScript>();
            bootsItemScript.item = boots;
            Image bootsItemImage = bootsItem.GetComponent<Image>();
            bootsItemImage.sprite = bootsSprite;
        }
    }
}
