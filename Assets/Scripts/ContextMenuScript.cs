using UnityEngine;
using UnityEngine.UI;
using System.Collections;

public class ContextMenuScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public GameObject equipButtonPrefab;
    public GameObject learnButtonPrefab;
    public GameObject salvageButtonPrefab;

    public IEnumerator BuildButtons(GameObject inventoryItem)
    {
        // clear any existing buttons
        for (int i = 0; i < this.transform.childCount; i++)
        {
            Destroy(this.transform.GetChild(i).gameObject);
        }
        InventoryItemScript inventoryItemScript = inventoryItem.GetComponent<InventoryItemScript>();
        GameObject item = inventoryItemScript.item;
        ItemScript itemScript = item.GetComponent<ItemScript>();
        while (!finishedBuilding)
        {
            yield return null;
        }
        switch (itemScript.ItemType())
        {
            case "Weapon":
                GameObject mainHandButton = Instantiate(equipButtonPrefab, this.transform);
                EquipButtonScript mainHandButtonScript = mainHandButton.GetComponent<EquipButtonScript>();
                mainHandButtonScript.targetTransform = playerScript.mainHand;
                mainHandButtonScript.selectedItem = item;
                StartCoroutine(mainHandButtonScript.SetText("Equip to main hand"));

                GameObject offHandButton = Instantiate(equipButtonPrefab, this.transform);
                EquipButtonScript offHandButtonScript = offHandButton.GetComponent<EquipButtonScript>();
                offHandButtonScript.targetTransform = playerScript.offHand;
                offHandButtonScript.selectedItem = item;
                StartCoroutine(offHandButtonScript.SetText("Equip to off hand"));
                break;
            case "Coat":
                GameObject coatButton = Instantiate(equipButtonPrefab, this.transform);
                EquipButtonScript coatButtonScript = coatButton.GetComponent<EquipButtonScript>();
                coatButtonScript.targetTransform = playerScript.body;
                coatButtonScript.selectedItem = item;
                StartCoroutine(coatButtonScript.SetText("Equip to body"));
                break;
            case "Gloves":
                GameObject glovesButton = Instantiate(equipButtonPrefab, this.transform);
                EquipButtonScript glovesButtonScript = glovesButton.GetComponent<EquipButtonScript>();
                glovesButtonScript.targetTransform = playerScript.hands;
                glovesButtonScript.selectedItem = item;
                StartCoroutine(glovesButtonScript.SetText("Equip to hands"));
                break;
            case "Pants":
                GameObject pantsButton = Instantiate(equipButtonPrefab, this.transform);
                EquipButtonScript pantsButtonScript = pantsButton.GetComponent<EquipButtonScript>();
                pantsButtonScript.targetTransform = playerScript.legs;
                pantsButtonScript.selectedItem = item;
                StartCoroutine(pantsButtonScript.SetText("Equip to legs"));
                break;
            case "Boots":
                GameObject bootsButton = Instantiate(equipButtonPrefab, this.transform);
                EquipButtonScript bootsButtonScript = bootsButton.GetComponent<EquipButtonScript>();
                bootsButtonScript.targetTransform = playerScript.feet;
                bootsButtonScript.selectedItem = item;
                StartCoroutine(bootsButtonScript.SetText("Equip to feet"));
                break;
            case "Tome":
                SkillTomeScript tomeScript = item.GetComponent<SkillTomeScript>();
                GameObject learnButton = Instantiate(learnButtonPrefab, this.transform);
                LearnButtonScript learnButtonScript = learnButton.GetComponent<LearnButtonScript>();
                learnButtonScript.skillName = tomeScript.skillName;
                learnButtonScript.selectedItem = item;
                break;
        }
        int[] itemSalvage = itemScript.SalvageValue();
        GameObject salvageButton = Instantiate(salvageButtonPrefab, this.transform);
        SalvageButtonScript salvageButtonScript = salvageButton.GetComponent<SalvageButtonScript>();
        salvageButtonScript.salvageValue = itemSalvage;
        salvageButtonScript.selectedItem = item;
        StartCoroutine(salvageButtonScript.SetText(itemSalvage));
    }

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        equipButtonPrefab = Resources.Load<GameObject>("Prefabs/Equip Button");
        learnButtonPrefab = Resources.Load<GameObject>("Prefabs/Learn Button");
        salvageButtonPrefab = Resources.Load<GameObject>("Prefabs/Salvage Button");
        finishedBuilding = true;
    }
}
