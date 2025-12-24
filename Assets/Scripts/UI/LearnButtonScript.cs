using UnityEngine;
using UnityEngine.UI;
using TMPro;

public class LearnButtonScript : MonoBehaviour
{
    public Button button;
    public string skillName;
    public GameObject selectedItem;

    public void OnActivate()
    {
        PlayerDataScript playerDataScript = PlayerDataScript.Instance;
        if (skillName == null || selectedItem == null)
        {
            Debug.LogError("skillName or selectedItem have not been set yet");
            return;
        }
        if (playerDataScript.unlockedSkills.Contains(skillName))
        {
            Debug.Log("this skill is already unlocked");
        }
        else
        {
            playerDataScript.unlockedSkills.Add(skillName);
            DestroyImmediate(selectedItem);
            // refresh open menus
            Transform characterUI = GameObject.Find("Character UI").transform;
            Transform inventoryMenu = characterUI.Find("Inventory Menu(Clone)");
            if (inventoryMenu != null)
            {
                InventoryMenuScript inventoryMenuScript = inventoryMenu.GetComponent<InventoryMenuScript>();
                inventoryMenuScript.RefreshUI();
            }
            Transform skillsMenu = characterUI.Find("Skills Menu(Clone)");
            if (skillsMenu != null)
            {
                SkillsMenuScript skillsMenuScript = skillsMenu.GetComponent<SkillsMenuScript>();
                skillsMenuScript.RefreshUI();
            }
            // close context menu
            Transform canvas = GameObject.Find("Canvas").transform;
            Transform contextMenu = canvas.Find("Context Menu");
            if (contextMenu != null)
            {
                Destroy(contextMenu.gameObject);
            }
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
