using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;

public class SkillsButtonScript : MonoBehaviour
{
    public Button button;
    public Transform characterUI;
    public GameObject skillsMenuPrefab;
    public GameObject skillsMenu;

    public void OnActivate()
    {
        if (skillsMenu == null)
        {
            skillsMenu = Instantiate(skillsMenuPrefab, characterUI);
        }
        else
        {
            Destroy(skillsMenu);
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        characterUI = GameObject.Find("Character UI").transform;
        skillsMenuPrefab = Resources.Load<GameObject>("Prefabs/Skills Menu");
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard != null)
        {
            if (keyboard.pKey.wasPressedThisFrame)
            {
                OnActivate();
            }
        }
    }
}
