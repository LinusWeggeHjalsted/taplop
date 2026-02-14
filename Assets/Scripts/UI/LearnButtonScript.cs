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
        SoundControllerScript.Instance.PlayLearnSkillSound();
        PlayerDataScript playerDataScript = PlayerDataScript.Instance;
        if (skillName == null || selectedItem == null)
        {
            Debug.LogError("skillName or selectedItem have not been set yet");
            return;
        }
        if (playerDataScript.unlockedSkills.Contains(skillName))
        {
        }
        else
        {
            playerDataScript.unlockedSkills.Add(skillName);
            DestroyImmediate(selectedItem);
            // refresh open menus
            Transform characterUI = GameReferences.GetCharacterUI().transform;
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
            Transform canvas = GameReferences.GetCanvasTransform();
            Transform contextMenu = canvas.Find("Context Menu");
            if (contextMenu != null)
            {
                Destroy(contextMenu.gameObject);
            }
        }
    }

    void Awake()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
